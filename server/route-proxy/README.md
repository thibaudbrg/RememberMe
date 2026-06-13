# rm-route-proxy

Anonymous Google Directions proxy for the RememberMe iOS app, running on
Cloudflare Workers.

It lets genuine, unmodified app builds fetch Google Directions routes using a
developer-held API key **without the key ever reaching devices, and without the
server learning anything about users.** Access is gated by Apple **App Attest**:
the device proves it is a real instance of our app on real Apple hardware; the
server never sees coordinates beyond the single in-flight request, and never
stores or logs them.

---

## Architecture in one paragraph

The iOS app generates an App Attest key, fetches a one-time challenge
(`/v1/attest-challenge`), and enrolls once with `/v1/attest` (proving the key
belongs to a genuine build). The server stores only the attested public key +
a replay counter. From then on, every `/v1/route` request carries an App Attest
**assertion** (a per-request signature over the exact request body). The server
verifies the signature, advances the counter, rate-limits, validates the
coordinates, forwards to Google with the secret key, and returns a **trimmed**
response containing only the fields the client decodes.

---

## App Attest verification approach (and why)

Verification is **hand-rolled** on the WebCrypto API, not the `node-app-attest`
npm package.

`node-app-attest` relies on `crypto.X509Certificate`, `crypto.createVerify`, and
the Node-stream `cbor` package. `crypto.X509Certificate` is **not implemented in
the Workers runtime** even with `nodejs_compat` (workerd issue #1304), so the
library cannot verify the certificate chain there. Instead this worker uses:

- **`@peculiar/x509`** — built directly on WebCrypto — for the x5c certificate
  chain verification and extension parsing. It is bound to the Workers-provided
  global `crypto` via `x509.cryptoProvider.set(crypto)`.
- **`cbor-x`** — a pure-JS CBOR codec — to decode the attestation and assertion
  objects.
- **`@peculiar/asn1-schema` + `@peculiar/asn1-x509`** to parse the
  SubjectPublicKeyInfo and recover the raw EC public-key point for the keyId hash.
- **`crypto.subtle`** for all SHA-256 hashing and ECDSA-P256 signature verification.

> Note: `@peculiar/x509` pulls in `tsyringe`, which requires a `reflect-metadata`
> polyfill. `src/index.ts` imports `reflect-metadata` as its very first line. Do
> not remove that import.

Verification follows Apple's spec
(<https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server>):
chain up to the pinned **Apple App Attest Root CA G1**, nonce =
`SHA256(authData ‖ SHA256(challenge))` in credCert extension OID
`1.2.840.113635.100.8.2`, `rpIdHash == SHA256(teamId.bundleId)`,
`keyId == base64(SHA256(rawPubKey))`, aaguid `appattest` (prod) /
`appattestdevelop` (dev), counter `== 0`.

---

## Prerequisites

- A Cloudflare account (already created) with Workers + KV enabled.
- A Google Cloud project where you can create an API key and set a quota cap.
- Node 18+ and npm.

---

## One-time setup

### 1. Install

```sh
cd server/route-proxy
npm install
```

### 2. Log in to Cloudflare

```sh
npx wrangler login
```

### 3. Create the KV namespaces (prod + dev) and paste the ids

```sh
# Production namespace:
npx wrangler kv namespace create RM_KV
# Dev namespace:
npx wrangler kv namespace create RM_KV --env dev
```

Each command prints an `id`. Open `wrangler.toml` and replace the two
`id = "REPLACE_ME"` placeholders:

- the one under the top-level `[[kv_namespaces]]` → production id
- the one under `[[env.dev.kv_namespaces]]` → dev id

### 4. Set the secrets

```sh
# Production:
npx wrangler secret put GOOGLE_MAPS_KEY

# Dev (separate worker, needs its own copy of the key + the dev bypass secret):
npx wrangler secret put GOOGLE_MAPS_KEY --env dev
npx wrangler secret put DEV_SHARED_SECRET --env dev
```

Secrets are never written to `wrangler.toml` or any file in the repo.

### 5. Google Cloud setup

1. In Google Cloud Console → **APIs & Services → Credentials**, create an API key.
2. **Restrict it to the Directions API ONLY** (API restrictions → Directions API).
   Application restrictions can stay "None" — the key lives only on this server.
3. **APIs & Services → Directions API → Quotas**: set a **daily request cap**
   (e.g. **5000 requests/day**) so a runaway can never exceed your budget. This is
   the **hard backstop** (see the rate-limit caveat below).
4. **Billing → Budgets & alerts**: add a budget alert so you get notified before
   the cap is hit.

Use this key value when running `wrangler secret put GOOGLE_MAPS_KEY`.

### 6. Deploy

```sh
# Production:
npx wrangler deploy

# Dev:
npx wrangler deploy --env dev
```

`wrangler deploy` prints the worker's `*.workers.dev` URL. **The iOS client's
base-URL constant must match this URL exactly** (production points at
`rm-route-proxy`, dev at `rm-route-proxy-dev`).

---

## Key rotation (Google API key)

1. Create a new restricted key in Google Cloud (same Directions-only restriction
   + quota cap).
2. `npx wrangler secret put GOOGLE_MAPS_KEY` (and `--env dev`) with the new value.
3. `npx wrangler deploy` (and `--env dev`). New requests immediately use the new key.
4. **Disable / delete the old key** in Google Cloud.

No device-side change is required — the key never leaves the server.

---

## Local dev testing

`wrangler dev --local` runs the worker with a simulated KV. The App Attest
path cannot be exercised locally (it needs real Apple hardware), so for local
testing use the **dev bypass** instead.

Create a gitignored `.dev.vars` (already in `.gitignore`):

```
DEV_SHARED_SECRET=dev-secret-local
GOOGLE_MAPS_KEY=<a-real-or-fake-directions-key>
```

Then:

```sh
npx wrangler dev --local --var DEV_BYPASS:true
```

The dev bypass (`X-Dev-Secret`) is **only** honored when `DEV_BYPASS === "true"`,
which is set in `[env.dev]` and never in production.

### Example curl commands

```sh
B=http://localhost:8799   # adjust to wrangler's printed port

# Challenge endpoint returns a base64 challenge:
curl -X POST "$B/v1/attest-challenge"
# -> {"challenge":"...base64..."}

# Happy path (dev bypass) — forwards to Google and returns the trimmed body:
curl -X POST "$B/v1/route" \
  -H 'X-Dev-Secret: dev-secret-local' \
  -d '{"origin":"48.8566,2.3522","destination":"48.8606,2.3376","mode":"transit"}'

# 401 on a bad/absent secret:
curl -i -X POST "$B/v1/route" -H 'X-Dev-Secret: wrong' \
  -d '{"origin":"48.8566,2.3522","destination":"48.8606,2.3376","mode":"walking"}'

# 400 on a malformed body (bad coordinate / unknown mode):
curl -i -X POST "$B/v1/route" -H 'X-Dev-Secret: dev-secret-local' \
  -d '{"origin":"999,2.0","destination":"3.0,4.0","mode":"walking"}'

# 429 loop — fire >30 requests in one minute with the same key:
for i in $(seq 1 35); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST "$B/v1/route" \
    -H 'X-Dev-Secret: dev-secret-local' \
    -d '{"origin":"48.8566,2.3522","destination":"48.8606,2.3376","mode":"walking"}'
done
```

---

## API contract (for the iOS client)

All endpoints are **POST**. Any other method → **405**; unknown path → **404**.

### `POST /v1/attest-challenge`
- Response `200`: `{"challenge":"<base64>"}` — 32 random bytes, valid 300s, one-shot.

### `POST /v1/attest`
- Body: `{"keyId":"<base64>","attestation":"<base64>","challenge":"<base64>"}`.
- `204` on success (key enrolled). `400` on any failure
  (`unknown_challenge`, `attestation_failed`, `bad_body`).

### `POST /v1/route`
- Headers: `X-Attest-Key-Id: <base64 keyId>` + `X-Attest-Assertion: <base64 assertion>`.
  - The assertion must be the App Attest assertion over the **exact raw request
    body bytes** the client sends. Sign the bytes you transmit verbatim.
- Body (validated strictly):
  ```json
  {"origin":"lat,lng","destination":"lat,lng","mode":"walking|driving|transit"}
  ```
  - `origin`/`destination` must match `^-?\d{1,3}\.\d{1,6},-?\d{1,3}\.\d{1,6}$`,
    lat ∈ [-90,90], lng ∈ [-180,180]. The server rounds to 4 decimals server-side.
  - `alternatives=true` is always sent to Google; the client need not pass it.
- Responses:
  - `200`: trimmed Directions JSON (see below). Note: Google **application-level**
    statuses such as `ZERO_RESULTS` / `REQUEST_DENIED` come back as `200` with that
    `status` in the trimmed body — the client must read `body.status`.
  - `400 bad_request` / `bad_json`: invalid body.
  - `401 unauthorized`: unknown key / bad assertion / counter not advanced.
  - `429 rate_limited`: per-key (30/min) or global (5000/day) limit hit.
  - `502 upstream_error`: Google **HTTP-level** failure.
  - `504 upstream_error`: Google timeout (15s) / network error.

### Trimmed route response shape

Only these fields are ever returned (everything else from Google is dropped):

```
status, error_message?
routes[]:
  summary?, warnings?[]
  overview_polyline.points?
  legs[]:
    duration.value?, distance.value?
    steps[]:
      travel_mode?, polyline.points?, duration.value?, distance.value?
      transit_details.line.{ name?, short_name?, vehicle:{ name?, type? } }?
```

Dropped: addresses, place_ids, copyrights, fares, geocoded_waypoints,
html_instructions, bounds, viewport, lat/lng start/end locations, etc.

---

## Anonymity guarantees

**What is stored in KV (the only state):**
- `key:<keyId>` → `{ publicKeySpkiB64, counter, createdAt }` — the attested public
  key and its replay counter. No user identity, no device identifier beyond the
  App Attest key the device itself generated.
- `chal:<base64>` → short-lived (300s) one-shot attestation challenges.
- `rl:<keyId>:<minute>` and `rl:global:<day>` → short-lived rate counters.

**What is NEVER stored or logged, anywhere:**
- Coordinates, request bodies, or any route content.
- IP addresses.
- The Google Maps API key.

`observability` is disabled in `wrangler.toml`, so Cloudflare keeps no request
telemetry. Error paths return only generic codes (`unauthorized`,
`attestation_failed`, `upstream_error`, …) — no payloads, no coordinates, no key
material. There are no cookies, no analytics, and no CORS headers (the client is
the native app).

---

## Soft-rate-limit caveat

The per-key (30/min) and global (5000/day) limits are implemented with KV
counters. **KV is eventually consistent**, so under concurrent bursts a handful
of requests beyond the nominal limit can slip through (read-before-write race).
These are therefore **soft** limits, intended to stop casual abuse cheaply.

The **hard** backstop against cost is the **Google Cloud daily quota cap** you set
on the API key (step 5 above). Set it to a value you are comfortable paying for;
the soft limits keep you well under it in normal operation.
