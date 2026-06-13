// Soft rate limiting via KV counters.
//
// KV is eventually consistent, so these are SOFT limits — under concurrent bursts a
// few extra requests can slip through. That is acceptable: the hard backstop is the
// Google Cloud daily quota cap on the API key (see README). We keep counters keyed
// only by attested keyId and time bucket — never by IP or coordinates.

const PER_KEY_LIMIT = 30; // requests per minute per attested key
const PER_KEY_TTL = 120; // seconds
const GLOBAL_LIMIT = 5000; // requests per day across all keys
const GLOBAL_TTL = 90000; // seconds (~25h, covers a full UTC day)

export type RateResult = "ok" | "per_key" | "global";

export async function checkAndIncrement(kv: KVNamespace, keyId: string): Promise<RateResult> {
  const now = Date.now();
  const minute = Math.floor(now / 60000);
  const day = Math.floor(now / 86400000);

  const perKeyKey = `rl:${keyId}:${minute}`;
  const globalKey = `rl:global:${day}`;

  const [perKeyCount, globalCount] = await Promise.all([
    readCount(kv, perKeyKey),
    readCount(kv, globalKey),
  ]);

  if (perKeyCount >= PER_KEY_LIMIT) return "per_key";
  if (globalCount >= GLOBAL_LIMIT) return "global";

  await Promise.all([
    kv.put(perKeyKey, String(perKeyCount + 1), { expirationTtl: PER_KEY_TTL }),
    kv.put(globalKey, String(globalCount + 1), { expirationTtl: GLOBAL_TTL }),
  ]);

  return "ok";
}

async function readCount(kv: KVNamespace, key: string): Promise<number> {
  const v = await kv.get(key);
  if (v === null) return 0;
  const n = parseInt(v, 10);
  return Number.isFinite(n) ? n : 0;
}
