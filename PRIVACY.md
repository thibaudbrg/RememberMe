# Privacy

RememberMe is built around one rule: **your location history is yours and only yours.** This document explains, in plain terms, what that means in practice — what stays on your phone, what (if anything) leaves it, and what we *don't* try to defend against.

## Where your data lives

| Data                                  | Location                                                                          |
|---------------------------------------|-----------------------------------------------------------------------------------|
| Imported activities, visits, paths    | A single SQLite database on your iPhone, encrypted with SQLCipher (AES-256)       |
| Encryption key                        | iOS Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `synchronizable = false` |
| User-chosen place labels              | Same encrypted SQLite                                                             |
| Reverse-geocoded place names (cached) | Same encrypted SQLite, optional                                                   |
| Logs (development builds)             | OSLog; production builds round coordinates to ~1 km precision                     |

The SQLite file lives in the app sandbox under `NSFileProtectionComplete` and is marked `isExcludedFromBackup = true` — it does **not** end up in iTunes/Finder/iCloud backups.

## What leaves your device

Only the network calls Apple's own frameworks make on our behalf:

1. **Map tiles** — `MapKit` fetches vector/raster tiles from Apple. Apple's published policy is that these requests are not associated with your Apple ID. We do not add any extra identifiers.
2. **Reverse geocoding** — `CLGeocoder` is used on-demand to resolve coordinates → place names when you tap a visit. Results are cached locally so we don't ask twice.
3. **Search** — `MKLocalSearch` / `MKLocalSearchCompleter` when you use the search bar.

Beyond Apple's frameworks: **nothing.** There is no analytics SDK, no crash reporter, no third-party library that talks to the internet, no first-party server.

App Transport Security is set strict in `Info.plist`. Any future code path that tried to make an arbitrary network call would fail to compile or fail at runtime.

### Alpha features: path refinement

There is one opt-in feature, off by default, that issues additional outbound network calls: **path refinement**. Enabling it in Settings → Alpha features lets you ask a routing service for the route it would have suggested for a recorded trip, and replace the noisy GPS samples with that cleaner polyline.

The provider is a separate choice inside the alpha section. Each provider sees different data and has a different trust model. Switching to Google triggers a second, distinct disclosure sheet — flipping the alpha toggle is not consent to use Google.

#### Provider: Apple Maps (default)

| Data | Leaves device? | Mitigation |
|---|---|---|
| Trip start and end coordinates | Yes — to Apple Maps via `MKDirections` | Rounded to 4 decimals (~11 m) before the request is built |
| Transport mode (coarse) | Yes (as `MKDirectionsTransportType`) | Mapped to `.walking` / `.automobile` — Apple's API does **not** return transit polylines, so transit trips are skipped entirely (we never silently re-route them as driving) |
| Full GPS sample stream | No | Similarity scoring is computed locally |
| Place IDs, names, labels, dates | No | Never sent |
| User identity | No | `MKDirections` uses Apple's anonymized routing endpoints — no API key, no Apple ID binding |

#### Provider: Google Maps (requires your own API key)

| Data | Leaves device? | Mitigation |
|---|---|---|
| Trip start and end coordinates | Yes — to Google Directions API | Rounded to 4 decimals (~11 m) before the request is built |
| Transport mode (coarse) | Yes (as Google's `mode` parameter) | One of `walking` / `driving` / `transit` |
| Your personal Google Directions API key | Yes — on every request | You paste it into Settings; the app never ships with a key. Google attributes usage to your Google Cloud account, not the app developer |
| Your IP address | Yes — to Google's servers | Inherent in any HTTPS call to a third-party endpoint |
| Full GPS sample stream | No | Similarity scoring is computed locally |
| Place IDs, names, labels, dates | No | Never sent |

The Google provider exists specifically because Apple's `MKDirections` does not return transit polylines (confirmed by Apple DTS, [forum thread 663624](https://developer.apple.com/forums/thread/663624)). If you want to refine bus / train / subway trips, you must opt in to Google explicitly and bring your own key.

#### How to revert

Switch the provider picker back to Apple, or turn the alpha toggle off. Previously-refined trips stay refined; each can be reverted individually from the alpha screen.

## What happens if…

### …you lose your phone (locked)
The DB file is protected by `NSFileProtectionComplete`: it is inaccessible to anyone, including jailbreak toolkits, until the device is unlocked. The DB key in the Keychain is only available `WhenUnlocked`.

### …you lose your phone (unlocked, hours after last use)
The DB key remains available while the device is unlocked. If you enabled the optional **Face ID lock** in Settings, the app re-prompts before unwrapping the key. If you didn't, anyone with the unlocked phone can open the app.

### …iCloud backup is enabled
The DB file is excluded from backups. The Keychain item is marked `ThisDeviceOnly`. **A restore-to-new-iPhone will not bring your RememberMe data with it.** This is intentional — see "moving to a new iPhone" below.

### …you uninstall the app
iOS removes the app sandbox (DB, WAL, SHM files) and the Keychain item is dropped. The data is gone.

### …you want to wipe everything right now
Settings → "Wipe all data". This closes the database, deletes the DB + WAL + SHM, deletes the Keychain key, and resets the app. Irreversible.

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

- The `.xcconfig` enforces `NSAppTransportSecurity_NSAllowsArbitraryLoads = NO`.
- There are zero third-party Swift package dependencies that perform network I/O. Run `swift package show-dependencies --package-path Packages/Core` and `Packages/Persistence`.
- `grep -R "URLSession\|NSURLConnection" RememberMe/ Packages/` shows every network call site in the app. There should be none outside of `MKLocalSearch` / `CLGeocoder` adapter code.
- Database encryption is exercised by the test suite: `swift test --package-path Packages/Persistence` opens an encrypted DB, writes a row, closes it, and asserts (a) the raw bytes on disk do **not** start with the SQLite magic header `"SQLite format 3\0"` and (b) reopening with a different random key is rejected. See `Packages/Persistence/Tests/PersistenceTests/EncryptionSmokeTests.swift`.
