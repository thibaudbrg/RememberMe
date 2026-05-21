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
- Apple itself (we use MapKit, CLGeocoder, MKLocalSearch).

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
| File protection                | `NSFileProtectionComplete` (applied by the app target when it constructs the URL) |
| Backup exclusion               | `URLResourceValues.isExcludedFromBackup = true` set by `DatabaseFactory.open(at:)` |

### Why raw key, not passphrase

SQLCipher's passphrase PRAGMA triggers an internal PBKDF2 (256k iterations). Doing that on top of a 256-bit `SecRandomCopyBytes` key is wasted CPU and gains nothing — the key is already maximum-entropy. The raw-key form (`x'…'`) bypasses the KDF and uses the bytes directly.

## Keychain item for the DB key

```
kSecClass             = kSecClassGenericPassword
kSecAttrService       = "RememberMe.DB"
kSecAttrAccount       = "primary"
kSecAttrAccessible    = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
kSecAttrSynchronizable = false
kSecValueData         = <32 random bytes>
```

When the optional **Face ID lock** is on, the Keychain item is recreated with an access control:

```
SecAccessControlCreateWithFlags(
    nil,
    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    [.biometryCurrentSet, .or, .devicePasscode],
    &error)
```

`.biometryCurrentSet` means: enrolling a new fingerprint / Face ID face invalidates the item (and thus the DB becomes unreadable). The user must keep the export they made before changing biometrics, or accept data loss. This is documented to the user when they toggle the lock on.

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

`SettingsService.wipeEverything()`:

```
1. GRDBPool.shared.close()                       // release file handles
2. FileManager.removeItem(at: dbURL)             // delete <sandbox>/db.sqlite
3. FileManager.removeItem(at: dbURL + "-wal")    // ignore "not found"
4. FileManager.removeItem(at: dbURL + "-shm")    // ignore "not found"
5. SecItemDelete([kSecClass: GenericPassword, kSecAttrService: "RememberMe.DB"])
6. UserDefaults.standard.removePersistentDomain(forName: bundleID)
7. exit(0)  // next launch is a first-launch path
```

`step 7` is debatable; an alternative is to soft-restart the app's root view. Whichever ships, it must be documented and reachable from a single tap (with a confirmation sheet).

## Network policy

`Info.plist`:

```
NSAppTransportSecurity = { NSAllowsArbitraryLoads = NO }
```

Allowed network code paths in the app target:
- `MapKit` (tile loading, no app code involved).
- `CLGeocoder.reverseGeocodeLocation(_:)`.
- `MKLocalSearchCompleter` / `MKLocalSearch`.

Anything else (`URLSession`, `URLDownloadTask`, raw sockets) is **forbidden** in app code. The pre-commit hook + CI grep enforce this by rejecting new commits that introduce `URLSession` outside an allowlisted file. If you ever genuinely need it, change the allowlist + update this document in the same PR.

## Reporting a vulnerability

There is no bug bounty. If you find a real flaw — in the crypto choices, the key handling, the export format, the import path, or anywhere else — please open an issue on the GitHub repo with a sensible title and the technical details. If the issue is sensitive enough that public disclosure feels wrong, ping the maintainer first and we'll figure it out.
