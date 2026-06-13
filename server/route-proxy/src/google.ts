// Forward a validated route request to the Google Directions API and return the
// trimmed response. The Google API key lives ONLY in this module's env access and
// is never logged, never returned, and never reaches the device.

import { trimDirections, type TrimmedDirections } from "./trim.js";

const GOOGLE_TIMEOUT_MS = 15000;

export type Mode = "walking" | "driving" | "transit";

export interface RouteRequest {
  origin: string; // "lat,lng" already validated + rounded
  destination: string; // "lat,lng" already validated + rounded
  mode: Mode;
}

export type GoogleResult =
  | { ok: true; body: TrimmedDirections }
  | { ok: false; status: 502 | 504 };

export async function fetchDirections(req: RouteRequest, apiKey: string): Promise<GoogleResult> {
  const url = new URL("https://maps.googleapis.com/maps/api/directions/json");
  url.searchParams.set("origin", req.origin);
  url.searchParams.set("destination", req.destination);
  url.searchParams.set("mode", req.mode);
  url.searchParams.set("alternatives", "true");
  url.searchParams.set("key", apiKey);

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), GOOGLE_TIMEOUT_MS);

  let resp: Response;
  try {
    resp = await fetch(url.toString(), { method: "GET", signal: controller.signal });
  } catch {
    // Network error or timeout abort. Never log the URL (it carries coordinates).
    return { ok: false, status: 504 };
  } finally {
    clearTimeout(timer);
  }

  if (!resp.ok) {
    // Google HTTP-level failure → 502 to the client. No body/coords logged.
    return { ok: false, status: 502 };
  }

  let json: unknown;
  try {
    json = await resp.json();
  } catch {
    return { ok: false, status: 502 };
  }

  return { ok: true, body: trimDirections(json) };
}
