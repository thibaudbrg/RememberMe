# RememberMe export format — `rememberme-export-v1`

A single, self-contained, passphrase-encrypted binary file. Suffix `.rmex`. Suitable for AirDrop, Files.app, USB, iCloud Drive — wherever the user wants. The passphrase is the only thing that protects it; the format is otherwise public.

## File layout

```
offset  size      field
------  --------  --------------------------------------------------------------
 0      4 bytes   magic       ASCII "RMEX"
 4      4 bytes   hdr_len     uint32, little-endian
 8      hdr_len   header_json UTF-8 JSON, see "Header" below
 8+L    ...       ciphertext  ChaChaPoly combined (ciphertext || 16-byte tag)
```

## Header (JSON, UTF-8)

```json
{
  "v": 1,
  "kdf": "argon2id",
  "m": 65536,
  "t": 3,
  "p": 1,
  "salt": "<base64, exactly 16 bytes>",
  "nonce": "<base64, exactly 12 bytes>",
  "aad": "rememberme-export-v1"
}
```

- `v` — format version. Bump when the wire format changes.
- `kdf` — currently only `"argon2id"`. Other values reserved for future use.
- `m` — Argon2id memory cost in **KiB** (64 MiB).
- `t` — Argon2id iterations.
- `p` — Argon2id parallelism.
- `salt` — base64-encoded 16 random bytes from `SecRandomCopyBytes`.
- `nonce` — base64-encoded 12 random bytes for ChaChaPoly.
- `aad` — additional authenticated data, **always** the literal string `rememberme-export-v1`. The decoder rejects mismatches.

## Encryption

```
key        = Argon2id(passphrase=<UTF-8>, salt=<from header>, m, t, p, len=32)
ciphertext = ChaChaPoly.seal(plaintext=<payload UTF-8>, key, nonce, aad).combined
```

The header is **authenticated** via `aad`: an attacker can't downgrade `m` / `t` / `p` to make brute-forcing easier without invalidating the auth tag.

## Plaintext payload (after decryption)

```json
{
  "version": 1,
  "exported_at": "2026-05-21T11:00:00Z",
  "device_name": "<user-editable, defaults to UIDevice.current.name>",
  "events": [
    {
      "id": "<ulid>",
      "kind": "activity",
      "start_ts": 1716285360,
      "start_tz_offset_min": 120,
      "end_ts":   1716288660,
      "end_tz_offset_min":   120,
      "source": "google-takeout-2023-08-23",
      "imported_at": 1716000000,
      "activity": {
        "start_lat": 47.060450, "start_lon": 6.593421,
        "end_lat":   46.997669, "end_lon":   6.943593,
        "distance_m": 29132,
        "mode": "in passenger vehicle",
        "probability": 0.0
      }
    },
    {
      "id": "<ulid>",
      "kind": "visit",
      "start_ts": ..., "start_tz_offset_min": ...,
      "end_ts":   ..., "end_tz_offset_min":   ...,
      "visit": {
        "place_id": "ChIJ...",
        "lat": ..., "lon": ...,
        "semantic_type": "Home",
        "hierarchy_level": 0,
        "probability": 0.93
      }
    },
    {
      "id": "<ulid>",
      "kind": "path",
      "start_ts": ..., "start_tz_offset_min": ...,
      "end_ts":   ..., "end_tz_offset_min":   ...,
      "path": [
        { "lat": 46.997, "lon": 6.944, "offset_min": 0 },
        { "lat": 46.998, "lon": 6.942, "offset_min": 7 }
      ]
    }
  ],
  "places": [
    {
      "place_id": "ChIJ...",
      "user_label": "Home",
      "resolved_label": "12 rue de la Paix, Paris",
      "resolved_at": 1716000000,
      "lat": ..., "lon": ...
    }
  ]
}
```

## Implementation notes

- `Argon2id` is not in Apple's CryptoKit. We use either [tesseract-one/swift-argon2id](https://github.com/tesseract-one/Argon2.swift) or a small wrapper around libsodium's Argon2. The chosen implementation is locked in `Packages/Core` at first crypto commit.
- The export is produced and consumed entirely on-device. There is no server roundtrip.
- An importer that sees a higher `v` than it knows about must refuse rather than guess.
- A round-trip test vector at `fixtures/rememberme-export-minimal.bin` (passphrase `"test"`) will land alongside the first crypto commit, so other decoders can verify against ours.
