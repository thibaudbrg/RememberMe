// rm-route-proxy — anonymous Google Directions proxy for RememberMe.
//
// Anonymity invariants (enforced here and in the helper modules):
//  - We never log or store coordinates, request bodies, IPs, or the Google key.
//  - KV holds ONLY: attested keys (keyId -> pubkey/counter/createdAt), short-TTL
//    challenges, short-TTL rate counters.
//  - observability is disabled in wrangler.toml.
//  - No cookies / no analytics / no CORS (native client). Unknown paths -> 404,
//    wrong method -> 405.

// Required first: @peculiar/x509 depends on tsyringe, which needs a reflect-metadata
// polyfill installed before any of its decorated classes are evaluated.
import "reflect-metadata";

import {
  verifyAttestation,
  verifyAssertion,
  AttestError,
  b64encode,
  b64decode,
  type AppAttestEnv,
} from "./attest.js";
import { checkAndIncrement } from "./ratelimit.js";
import { fetchDirections, type Mode } from "./google.js";

export interface Env {
  RM_KV: KVNamespace;
  APPLE_TEAM_ID: string;
  APPLE_BUNDLE_ID: string;
  APPATTEST_ENV: string; // "production" | "development"
  DEV_BYPASS: string; // "true" enables X-Dev-Secret bypass (dev env only)
  GOOGLE_MAPS_KEY: string; // secret
  DEV_SHARED_SECRET?: string; // secret, dev env only
}

const CHALLENGE_TTL = 300; // seconds
const COORD_RE = /^-?\d{1,3}\.\d{1,6},-?\d{1,3}\.\d{1,6}$/;
const MODES: ReadonlySet<string> = new Set(["walking", "driving", "transit"]);

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;

    if (req.method !== "POST") return json405();

    try {
      if (path === "/v1/attest-challenge") return await handleChallenge(env);
      if (path === "/v1/attest") return await handleAttest(req, env);
      if (path === "/v1/route") return await handleRoute(req, env);
      return json404();
    } catch {
      // Generic catch-all. Never surface internal details or payloads.
      return jsonError(500, "internal_error");
    }
  },
} satisfies ExportedHandler<Env>;

// ---------------------------------------------------------------------------
// POST /v1/attest-challenge
// ---------------------------------------------------------------------------

async function handleChallenge(env: Env): Promise<Response> {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const challenge = b64encode(bytes);
  // One-shot: stored under the challenge value itself, consumed on /v1/attest.
  await env.RM_KV.put(`chal:${challenge}`, "1", { expirationTtl: CHALLENGE_TTL });
  return jsonResponse(200, { challenge });
}

// ---------------------------------------------------------------------------
// POST /v1/attest
// ---------------------------------------------------------------------------

async function handleAttest(req: Request, env: Env): Promise<Response> {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return jsonError(400, "bad_json");
  }
  if (typeof body !== "object" || body === null) return jsonError(400, "bad_body");
  const b = body as Record<string, unknown>;
  const keyId = b["keyId"];
  const attestation = b["attestation"];
  const challenge = b["challenge"];
  if (typeof keyId !== "string" || typeof attestation !== "string" || typeof challenge !== "string") {
    return jsonError(400, "bad_body");
  }

  // Challenge must exist; delete it (one-shot) before doing expensive work.
  const chalKey = `chal:${challenge}`;
  const exists = await env.RM_KV.get(chalKey);
  if (exists === null) return jsonError(400, "unknown_challenge");
  await env.RM_KV.delete(chalKey);

  let verified;
  try {
    verified = await verifyAttestation({
      attestation: b64decode(attestation),
      challengeBytes: b64decode(challenge),
      keyId,
      teamId: env.APPLE_TEAM_ID,
      bundleId: env.APPLE_BUNDLE_ID,
      env: appAttestEnv(env),
    });
  } catch (e) {
    if (e instanceof AttestError) return jsonError(400, "attestation_failed");
    return jsonError(400, "attestation_failed");
  }

  await env.RM_KV.put(
    `key:${keyId}`,
    JSON.stringify({
      publicKeySpkiB64: verified.publicKeySpkiB64,
      counter: 0,
      createdAt: Date.now(),
    }),
  );

  return new Response(null, { status: 204 });
}

// ---------------------------------------------------------------------------
// POST /v1/route
// ---------------------------------------------------------------------------

interface StoredKey {
  publicKeySpkiB64: string;
  counter: number;
  createdAt: number;
}

async function handleRoute(req: Request, env: Env): Promise<Response> {
  // Read the raw body bytes ONCE — needed verbatim for assertion verification.
  const rawBody = new Uint8Array(await req.arrayBuffer());

  const devBypass = env.DEV_BYPASS === "true";
  const devSecret = req.headers.get("X-Dev-Secret");

  let keyId: string | null = null;

  if (devBypass && devSecret !== null) {
    // Dev bypass: constant-time compare against the shared secret.
    if (!env.DEV_SHARED_SECRET || !timingSafeEqualStr(devSecret, env.DEV_SHARED_SECRET)) {
      return jsonError(401, "unauthorized");
    }
    keyId = "dev";
  } else {
    keyId = req.headers.get("X-Attest-Key-Id");
    const assertionB64 = req.headers.get("X-Attest-Assertion");
    if (!keyId || !assertionB64) return jsonError(401, "unauthorized");

    const storedRaw = await env.RM_KV.get(`key:${keyId}`);
    if (storedRaw === null) return jsonError(401, "unauthorized");
    const stored = parseStoredKey(storedRaw);
    if (!stored) return jsonError(401, "unauthorized");

    try {
      const result = await verifyAssertion({
        assertion: b64decode(assertionB64),
        rawBody,
        publicKeySpkiB64: stored.publicKeySpkiB64,
        teamId: env.APPLE_TEAM_ID,
        bundleId: env.APPLE_BUNDLE_ID,
        storedCounter: stored.counter,
      });
      // Persist the advanced counter (replay/clone protection).
      await env.RM_KV.put(
        `key:${keyId}`,
        JSON.stringify({ ...stored, counter: result.newCounter }),
      );
    } catch {
      return jsonError(401, "unauthorized");
    }
  }

  // Rate limit on the authenticated key (or "dev").
  const rl = await checkAndIncrement(env.RM_KV, keyId);
  if (rl !== "ok") return jsonError(429, "rate_limited");

  // Parse + strictly validate the body.
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(rawBody));
  } catch {
    return jsonError(400, "bad_json");
  }
  const route = validateRouteBody(parsed);
  if (!route) return jsonError(400, "bad_request");

  const result = await fetchDirections(route, env.GOOGLE_MAPS_KEY);
  if (!result.ok) return jsonError(result.status, "upstream_error");
  return jsonResponse(200, result.body);
}

interface ValidatedRoute {
  origin: string;
  destination: string;
  mode: Mode;
}

function validateRouteBody(input: unknown): ValidatedRoute | null {
  if (typeof input !== "object" || input === null) return null;
  const b = input as Record<string, unknown>;
  const origin = b["origin"];
  const destination = b["destination"];
  const mode = b["mode"];

  if (typeof origin !== "string" || typeof destination !== "string" || typeof mode !== "string") {
    return null;
  }
  if (!MODES.has(mode)) return null;

  const o = validateCoord(origin);
  const d = validateCoord(destination);
  if (!o || !d) return null;

  return { origin: o, destination: d, mode: mode as Mode };
}

// Validate "lat,lng" and round each component to 4 decimals (belt and braces).
function validateCoord(s: string): string | null {
  if (!COORD_RE.test(s)) return null;
  const parts = s.split(",");
  if (parts.length !== 2) return null;
  const lat = Number(parts[0]);
  const lng = Number(parts[1]);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  return `${round4(lat)},${round4(lng)}`;
}

function round4(n: number): number {
  return Math.round(n * 10000) / 10000;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function appAttestEnv(env: Env): AppAttestEnv {
  return env.APPATTEST_ENV === "development" ? "development" : "production";
}

function parseStoredKey(raw: string): StoredKey | null {
  try {
    const v = JSON.parse(raw) as Record<string, unknown>;
    if (typeof v["publicKeySpkiB64"] !== "string" || typeof v["counter"] !== "number") return null;
    return {
      publicKeySpkiB64: v["publicKeySpkiB64"],
      counter: v["counter"],
      createdAt: typeof v["createdAt"] === "number" ? v["createdAt"] : 0,
    };
  } catch {
    return null;
  }
}

function timingSafeEqualStr(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function jsonError(status: number, code: string): Response {
  return jsonResponse(status, { error: code });
}

function json404(): Response {
  return jsonError(404, "not_found");
}

function json405(): Response {
  return new Response(JSON.stringify({ error: "method_not_allowed" }), {
    status: 405,
    headers: { "content-type": "application/json", allow: "POST" },
  });
}
