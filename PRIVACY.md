# Privacy

RememberMe is built around one rule: **your location history is yours and only yours.** This document explains, in plain terms, what that means in practice — what stays on your phone, what (if anything) leaves it, and what we *don't* try to defend against.

## Where your data lives

| Data                                  | Location                                                                          |
|---------------------------------------|-----------------------------------------------------------------------------------|
| Imported activities, visits, paths    | A single SQLite database on your iPhone, encrypted with SQLCipher (AES-256)       |
| Encryption key                        | iOS Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `synchronizable = false` |
| User-chosen place labels              | Same encrypted SQLite                                                             |
| Reverse-geocoded place names (cached) | Same encrypted SQLite, optional                                                   |
| Logs                                  | OSLog; coordinates and place names are redacted by default in every build. Full precision is logged only in local dev builds compiled with the `VERBOSE_LOGGING` flag (never shipped) |

The SQLite file lives in the app sandbox under `NSFileProtectionCompleteUntilFirstUserAuthentication` and is marked `isExcludedFromBackup = true` — it does **not** end up in iTunes/Finder/iCloud backups. Between a reboot and your first unlock the file is unreadable; once you've unlocked the device for the first time after boot, it stays readable until the next reboot. This is the protection class background-tracking apps (and Apple's own Health, Photos, etc.) use, because background callbacks need to be able to write while the screen is off.

## What leaves your device

Only the network calls Apple's own frameworks make on our behalf:

1. **Map tiles** — `MapKit` fetches vector/raster tiles from Apple. Apple's published policy is that these requests are not associated with your Apple ID. We do not add any extra identifiers.
2. **Reverse geocoding** — `CLGeocoder` resolves coordinates → place names. This runs **automatically** for your unnamed visited places: a background pass starts when the app opens, comes to the foreground, and after an import, sending each unresolved place's coordinates to Apple at a throttled pace (up to a couple hundred per run). It also runs on demand the moment you tap a visit. Resolved names are cached locally so we don't ask twice.

Beyond Apple's frameworks: **nothing.** There is no analytics SDK, no crash reporter, no third-party library that talks to the internet, no first-party server.

App Transport Security is set strict in `Info.plist` (`NSAllowsArbitraryLoads = false`). Note what this does and does not do: ATS blocks cleartext and weak-TLS connections, so no plaintext HTTP traffic is possible. It does **not** block HTTPS calls to arbitrary hosts and has no compile-time effect — it is not, on its own, a guarantee that nothing is exfiltrated. The actual guarantee comes from there being no networking code beyond the Apple frameworks above and the route-refinement proxy below (see "Auditing this for yourself").

### Path refinement (Premium)

Path refinement — replacing a recorded trip's noisy GPS samples with the route a routing service suggests for the same A→B — is a paid feature. It is the only part of the app that talks to a non-Apple service. There is no toggle to find: the refine buttons are visible to everyone, and nothing is sent anywhere until you actually run a refinement.

Requests go to **RememberMe's routing proxy** (a Cloudflare Worker operated by the developer), which forwards them to Google's Directions API using a developer-held key. You never need a Google account or API key.

| Data | Leaves device? | Mitigation |
|---|---|---|
| Trip start and end coordinates | Yes — to the proxy, then Google | Rounded to 4 decimals (~11 m) before the request is built; the proxy re-rounds as belt-and-braces |
| Transport mode (coarse) | Yes | One of `walking` / `driving` / `transit` |
| Your IP address | Seen in transit by Cloudflare and Google | Inherent in any HTTPS call. The proxy does not log or store it |
| Full GPS sample stream | No | Similarity scoring is computed locally |
| Place IDs, names, labels, dates | No | Never sent |
| User identity / who paid | No | The proxy authenticates *that the request comes from a genuine build of this app* (Apple App Attest), never *who you are*. Premium is checked on-device only |

What the proxy is built to guarantee (its source is in this repo under `server/route-proxy/` — audit it):
- **No storage of request data.** It is a stateless pass-through; the only persisted state is the anonymous App Attest key registry and short-lived rate-limit counters.
- **No logging** of coordinates, request bodies, or IPs; Workers observability is disabled.
- **Trimmed responses.** Google's reply is stripped to the route geometry fields the app parses — addresses, place IDs and fare data Google echoes back are dropped at the proxy.
- **Rate limits + a hard daily quota cap** on the Google key bound the blast radius of any abuse.

#### Free-tier import window

Without Premium, importing a Google Takeout file keeps only the most recent 14 days of records (the rest are counted and skipped, entirely on-device — the file never leaves your phone either way). Unlocking Premium and re-importing the same file fills in the older records without duplicating anything.

#### How to revert

Previously-refined trips stay refined; each can be reverted individually from the trip's refinement screen.

## What happens if…

### …you lose your phone (locked, never unlocked since reboot)
Between a reboot and the first unlock, the DB file is protected by `NSFileProtectionCompleteUntilFirstUserAuthentication`: it is inaccessible to anyone, including jailbreak toolkits. The DB key in the Keychain is `AfterFirstUnlockThisDeviceOnly`, so before that first unlock it cannot be read either.

### …you lose your phone (locked, has been unlocked since reboot)
Once the device has been unlocked at least once since boot, both the DB file and its Keychain key become readable by the OS even while the screen is locked — this is exactly what allows live background tracking to keep recording while your screen is off. The trade-off is deliberate: the strong "inaccessible while locked" guarantee only holds in the never-unlocked-since-reboot state above. After first unlock, the data is still encrypted at rest by SQLCipher, but an attacker who can get the OS to hand over the Keychain item (e.g. via an exploit on a booted device) could reach it. If that is in your threat model, power the device off.

### …you lose your phone (unlocked, hours after last use)
The DB key remains available while the device is unlocked. If you enabled the optional **Face ID lock** in Settings, the app shows a Face ID prompt before displaying your history, and re-arms that prompt whenever the app leaves the foreground (so the app-switcher snapshot is covered too). This lock gates the app's interface only — the database key is still unwrapped at launch (including background launches for tracking) regardless of the lock; your data stays protected at rest by SQLCipher and the Keychain. If you didn't enable the lock, anyone with the unlocked phone can open the app.

### …iCloud backup is enabled
The DB file is excluded from backups. The Keychain item is marked `ThisDeviceOnly`. **A restore-to-new-iPhone will not bring your RememberMe data with it.** This is intentional — see "moving to a new iPhone" below.

### …you uninstall the app
iOS removes the app sandbox (DB, WAL, SHM files) and the Keychain item is dropped. The data is gone.

### …you want to wipe everything right now
There is no in-app "Wipe all data" button yet. To destroy your history right now, **uninstall the app** (see above): iOS removes the encrypted DB and its WAL/SHM sidecars with the sandbox, and drops the `ThisDeviceOnly` Keychain key. That is currently the complete, irreversible wipe path. An in-app one-tap wipe is planned.

## Moving to a new iPhone

By design, RememberMe is **not** portable across devices without your explicit involvement. The path is:

1. On the old phone: Settings → Export. Pick a strong passphrase.
2. You receive a single `*.rmex` file, encrypted with ChaChaPoly using a key derived from your passphrase via Argon2id. Store it however you like (Files.app, AirDrop to your Mac, a USB drive).
3. On the new phone: install RememberMe, Settings → Import, pick the file, enter the passphrase.

The passphrase is never sent anywhere. If you forget it, the export is unrecoverable. We do not hold a copy.

Format details: [docs/data-formats/rememberme-export-v1.md](docs/data-formats/rememberme-export-v1.md).

## What we do *not* defend against

Honesty matters more than reassurance:

- **An adversary who already has your decrypted database.** Latitude/longitude are stored at full precision; reverse-geocoding any public POI database against those coords recovers the places. SQLCipher protects the file at rest; once decrypted, it is what it is.
- **A jailbroken device with root.** All bets are off.
- **A device left unlocked next to a motivated attacker.** Use the optional Face ID lock; or use iOS's own auto-lock; or both.
- **Forensic recovery from device flash storage after a factory wipe.** iOS handles this via Effaceable Storage; we rely on the platform.
- **Apple itself.** Map tile + geocoding traffic goes to Apple servers. If that is part of your threat model, this app (and any app that uses MapKit) is not for you.

## Auditing this for yourself

The repo is open. To verify our claims:

- App Transport Security is enforced in `RememberMe/RememberMe/Resources/Info.plist`, which sets `NSAppTransportSecurity → NSAllowsArbitraryLoads = false`. (This blocks cleartext/weak-TLS only — see the note in "What leaves your device" above.)
- There are zero third-party Swift package dependencies that perform network I/O. Run `swift package show-dependencies --package-path Packages/Core` and `Packages/Persistence`.
- `grep -R "URLSession\|NSURLConnection" RememberMe/ Packages/` shows every network call site in the app. The only direct `URLSession` uses are `RememberMe/RememberMe/Features/Refinement/GoogleDirectionsRouter.swift` (the `RouteProxyRouter` — talks only to the hardcoded routing-proxy host) and `AppAttestService.swift` (the proxy's attestation handshake; the DeviceCheck framework itself also talks to Apple's attestation servers). Everything else goes through Apple's `MapKit` / `CLGeocoder` frameworks, which don't surface as `URLSession`.
- The routing proxy's full source is in `server/route-proxy/` in this repo — verify the no-logging / no-storage / response-trimming claims directly.
- Database encryption is exercised by the test suite: `swift test --package-path Packages/Persistence` opens an encrypted DB, writes a row, closes it, and asserts (a) the raw bytes on disk do **not** start with the SQLite magic header `"SQLite format 3\0"` and (b) reopening with a different random key is rejected. See `Packages/Persistence/Tests/PersistenceTests/EncryptionSmokeTests.swift`.
