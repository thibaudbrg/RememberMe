# Security

This is the engineer-facing companion to [PRIVACY.md](PRIVACY.md). It documents the exact cryptographic primitives, key lifecycle, and panic/wipe semantics that the app implements. If something in here doesn't match the code, the code is wrong — file an issue.

This is **not** a vulnerability disclosure document in the usual sense: RememberMe has no server and ships no managed service. There is nothing for us to "patch and deploy" — issues land as updates through the App Store like any iOS app.

## Threat model boundaries

In scope:
- Stolen *locked* device.
- iCloud / iTunes backup leakage.
- Network exfiltration from anywhere in the app's process.
- Accidental leak via git (a developer checks in a real `location-history.json`).

Out of scope (also in [PRIVACY.md](PRIVACY.md), enumerated here for completeness):
- Jailbroken device with root.
- Adversary who already has the *decrypted* database.
- Stolen device left unlocked.
- Coercion / rubber-hose attacks against the user.
- Apple itself (we use MapKit and CLGeocoder), Cloudflare (the routing proxy host), and Google (route refinement requests are forwarded to its Directions API).

## Database encryption

| Property                       | Value                                                                             |
|--------------------------------|-----------------------------------------------------------------------------------|
| Engine                         | SQLCipher via the official [`sqlcipher/SQLCipher.swift`](https://github.com/sqlcipher/SQLCipher.swift) SwiftPM package, wrapped by ~250 lines of audited Swift in `Packages/Persistence/Sources/Persistence/SQLCipherDatabase.swift` |
| Cipher                         | AES-256-CBC, page-level (SQLCipher default for v4)                                |
| Auth                           | HMAC-SHA512 per page                                                              |
| KDF inside SQLCipher           | Disabled effectively — we pass a raw 256-bit key, not a passphrase               |
| Key passing                    | `PRAGMA key = "x'<64 hex chars>'"` (raw key form). We do **not** use the passphrase form |
| Key length                     | 32 bytes (256 bits)                                                               |
| Key source                     | `SecRandomCopyBytes` on first launch (`Packages/Core/.../SecureRandom.swift`)     |
| File protection                | `NSFileProtectionCompleteUntilFirstUserAuthentication` (applied by the app target when it constructs the URL) — background location callbacks must be able to write while the screen is locked, which `NSFileProtectionComplete` would prevent |
| Backup exclusion               | `URLResourceValues.isExcludedFromBackup = true` set by `DatabaseFactory.open(at:)` |

### Why raw key, not passphrase

SQLCipher's passphrase PRAGMA triggers an internal PBKDF2 (256k iterations). Doing that on top of a 256-bit `SecRandomCopyBytes` key is wasted CPU and gains nothing — the key is already maximum-entropy. The raw-key form (`x'…'`) bypasses the KDF and uses the bytes directly.

## Keychain item for the DB key

```
kSecClass             = kSecClassGenericPassword
kSecAttrService       = "RememberMe.DB"
kSecAttrAccount       = "primary"
kSecAttrAccessible    = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
kSecAttrSynchronizable = false
kSecValueData         = <32 random bytes>
```

The item uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which pairs with the DB file's `NSFileProtectionCompleteUntilFirstUserAuthentication`: after the first unlock following a reboot, the key can be read while the screen is locked, so background location callbacks can keep writing. No `SecAccessControl` / biometric flags are set on the item.

The optional **Face ID lock** is a *UI gate only*. When it is on, the app presents an `LAContext` Face ID prompt before showing your history, and re-arms that prompt whenever the app leaves the foreground (so the app-switcher snapshot and a returning session are both protected). It does **not** gate unwrapping of the DB key: `ensureOpen()` reads the key and decrypts the database at launch regardless of the lock — including background launches for SLC/visit events, where no biometric prompt is possible and the key is needed to record the new fixes. The data remains protected at rest by SQLCipher and the Keychain's this-device-only class; the lock adds an interface curtain on top, not a cryptographic key binding.

## Encrypted export `rememberme-export-v1`

A single binary file. Format:

```
[ 4 bytes  ] magic = "RMEX" (ASCII)
[ 4 bytes  ] header_length, uint32 little-endian
[ N bytes  ] header_json (UTF-8):
            {
              "v": 1,
              "kdf": "argon2id",
              "m": 65536,      // memory cost in KiB (64 MiB)
              "t": 3,          // iterations
              "p": 1,          // parallelism
              "salt": "<base64, 16 random bytes>",
              "nonce": "<base64, 12 random bytes>",
              "aad": "rememberme-export-v1"
            }
[ rest     ] ChaChaPoly ciphertext, combined format (ciphertext || 16-byte tag)
```

Encryption: `ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)`, where:
- `plaintext` = UTF-8 of the export JSON
- `key` = Argon2id(passphrase, salt, m, t, p) → 32 bytes
- `aad` = the literal string `rememberme-export-v1`, so a forged header is rejected

Argon2id parameters chosen for ~1 second on a modern iPhone. The header is **authenticated** via `aad` so an attacker can't downgrade `m`/`t` without invalidating the tag.

## Panic / wipe

**Current behaviour: uninstall the app.** There is no in-app "Wipe all data" control today. To destroy your history, delete RememberMe from the Home Screen / Settings: iOS removes the app sandbox (the SQLCipher DB plus its `-wal`/`-shm` sidecars) and drops the Keychain item, which is `…ThisDeviceOnly` and never leaves the device. After that the data is unrecoverable.

### Planned (not yet implemented): in-app `wipeEverything()`

A future in-app wipe, reachable from a single tap behind a confirmation sheet, is specified below. **This is a design target, not a description of shipped code** — no such control exists in Settings yet:

```
1. close the SQLCipher database                  // release file handles
2. FileManager.removeItem(at: dbURL)             // delete <sandbox>/db.sqlite
3. FileManager.removeItem(at: dbURL + "-wal")    // ignore "not found"
4. FileManager.removeItem(at: dbURL + "-shm")    // ignore "not found"
5. SecItemDelete([kSecClass: GenericPassword, kSecAttrService: "RememberMe.DB"])
6. UserDefaults.standard.removePersistentDomain(forName: bundleID)
7. reset the app's root view to the first-launch path
```

## Network policy

`Info.plist`:

```
NSAppTransportSecurity = { NSAllowsArbitraryLoads = NO }
```

Allowed network code paths in the app target:
- `MapKit` (tile loading, no app code involved).
- `CLGeocoder.reverseGeocodeLocation(_:)`.
- `Features/Refinement/GoogleDirectionsRouter.swift` (`RouteProxyRouter`) and `AppAttestService.swift` — the only `URLSession` sites. Both talk exclusively to the hardcoded RememberMe routing-proxy host (a Cloudflare Worker whose source lives in `server/route-proxy/`); the `DeviceCheck` framework additionally talks to Apple's attestation servers as part of App Attest.

**Routing-proxy threat model.** The proxy holds the Google Directions key as a Worker secret (never shipped in the app, rotatable without an app update). It serves only requests carrying a valid App Attest assertion from a genuine build of this app — replay is blocked by a strictly-increasing per-key counter. It stores no coordinates, IPs, or request bodies (KV holds only attested public keys and short-TTL rate counters), logs nothing, trims Google's response to the geometry fields the client parses, and is bounded by per-device + global rate limits with a hard daily quota cap on the Google key as the cost backstop. Premium entitlement is deliberately *not* checked server-side — the proxy never learns who paid.

Anything else (`URLSession`, `URLDownloadTask`, raw sockets) is **forbidden** in app code. The pre-commit hook + CI grep enforce this by rejecting new commits that introduce `URLSession` outside an allowlisted file. If you ever genuinely need it, change the allowlist + update this document in the same PR.

## Reporting a vulnerability

There is no bug bounty. If you find a real flaw — in the crypto choices, the key handling, the export format, the import path, or anywhere else — please open an issue on the GitHub repo with a sensible title and the technical details. If the issue is sensitive enough that public disclosure feels wrong, ping the maintainer first and we'll figure it out.
