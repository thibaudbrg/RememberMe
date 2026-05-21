# RememberMe

A **local, privacy-first iOS replacement for Google Maps "Your Activity"**, dressed in an Apple-Maps-style UI. Everything stays on your phone, encrypted at rest. No accounts, no telemetry, no clouds.

- **iOS-native** SwiftUI + MapKit (iOS 17+)
- **Encrypted SQLite** via SQLCipher; key generated on-device, lives in the Keychain
- **Optional Face ID lock** (off by default)
- **Outbound network**: only Apple's own MapKit tiles and `CLGeocoder`/`MKLocalSearch`. No 3rd-party SDKs, no analytics
- **Import** your Google Takeout `location-history.json`; **export** a single encrypted file you can stash anywhere

Read the data flow and threat model in [PRIVACY.md](PRIVACY.md). Crypto specifics live in [SECURITY.md](SECURITY.md). Architecture notes in [docs/architecture.md](docs/architecture.md).

---

## Status

Scaffold only — no app code yet. The next round implements the Google Takeout importer against `fixtures/`, then the SQLCipher persistence layer, then the SwiftUI map + bottom drawer.

## Repo layout

```
RememberMe/                  iOS app (Xcode project)
Packages/Core/               models, importers, crypto helpers (pure Swift)
Packages/Persistence/        GRDB + SQLCipher schema + queries
docs/                        architecture, data formats
fixtures/                    synthetic, committed test data
sample-data/                 REAL user data, gitignored
scripts/                     one-shot dev helpers
```

## Quick start (developer)

```bash
# one-time setup: installs git hooks, lint tools (optional brew installs)
make setup

# open the workspace in Xcode
open RememberMe.xcworkspace
```

Build target is iPhone running iOS 17+. The app boots to a blank screen until features land.

## Importing your Google Takeout

1. From [Google Takeout](https://takeout.google.com/), export **Location History (Timeline)**. You'll get a folder with a `location-history.json` (iOS format) or `Records.json` + `Semantic Location History/` (Android/web format).
2. Drop the file under `sample-data/google-takeout/` for development — it stays out of git.
3. Once the importer ships, you'll trigger it from Settings → Import on-device.

## Privacy at a glance

| Question                                               | Answer                                              |
|--------------------------------------------------------|-----------------------------------------------------|
| Where does my data live?                               | Only on your iPhone, in an AES-256-encrypted SQLite |
| Does anything leave my device?                         | Only what Apple's own map/geocoding APIs send       |
| Can the developer (or anyone) read my data?            | No. There is no server                              |
| What happens if I lose my phone?                       | Data is unrecoverable unless you exported it        |
| What about iCloud backup?                              | Excluded by design                                  |
| What about a new iPhone?                               | Restore via your encrypted export file (you control the passphrase) |

Full details: [PRIVACY.md](PRIVACY.md).

## License

[MIT](LICENSE).
