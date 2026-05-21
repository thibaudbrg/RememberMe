# Architecture

This document captures the *why* behind the technical choices. The *what* is in the code; the *who/when* is in `git log`.

## High level

```
┌─────────────────────────────────────────────────────────┐
│                   RememberMe (iOS app)                  │
│  SwiftUI · MapKit · LocalAuthentication · CryptoKit     │
└──────────────┬────────────────────────────┬─────────────┘
               │                            │
               ▼                            ▼
       ┌──────────────┐            ┌─────────────────┐
       │  Packages/   │            │   Packages/     │
       │    Core      │◀───────────│   Persistence   │
       │              │            │                 │
       │  - Models    │            │  GRDB.swift +   │
       │  - Importers │            │  SQLCipher      │
       │  - Crypto    │            │                 │
       │  - Time      │            │                 │
       └──────────────┘            └─────────────────┘
```

`Core` is pure Swift, no UIKit, no GRDB. It defines the domain (events, activities, visits, paths, places), the Google Takeout decoder, and the crypto helpers (Keychain wrapper, export envelope). It can be unit-tested on macOS via `swift test`.

`Persistence` depends on `Core` and (will) depend on `GRDB.swift/SQLCipher`. It owns the SQLite schema, migrations, and all read/write queries.

The iOS app target is a thin shell on top: it composes both packages into the SwiftUI feature surface.

## Why two packages, not four

An earlier draft of the plan called for four packages (`Core`, `Crypto`, `Importers`, `Persistence`). After a critic pass we collapsed to two:

- `Crypto` was ~80 lines and `Importers` was ~300 lines of pure Swift. Carving each into its own SwiftPM product cost more in module-boundary annotation (`public` everywhere) than it bought in isolation.
- A future web app would share **schemas** (in `docs/data-formats/`) with this codebase, not Swift code — so the speculative "web-shareability" benefit of splitting `Core` further was unreal.
- We can always split further when `Core` grows past ~2k LOC.

## Why GRDB + SQLCipher and not Core Data

We considered three storage stacks:

1. **Core Data** with `NSPersistentStoreFileProtectionKey = .complete`.
   File-level protection only — when the device is unlocked, the file is plaintext on disk. The threat we care about (forensic readout of an unlocked, backgrounded app) is not covered.

2. **CryptoKit-encrypted blob files** (one big AES-GCM blob per "day" of events).
   Encryption ✅, but no query layer. Filtering visits by date range, joining to places, paginating a timeline — all become custom code over deserialized blobs. Doesn't scale.

3. **GRDB + SQLCipher** *(chosen)*.
   Page-level AES-256-CBC + HMAC-SHA512. Full SQL. Native Swift bindings.
   Cost: a C dependency (SQLCipher is a SQLite fork). SwiftPM integration is straightforward via the `GRDB.swift/SQLCipher` product.

We pass SQLCipher a raw 32-byte key (`PRAGMA key = "x'<hex>'"`), not a passphrase. The key comes from `SecRandomCopyBytes` and lives in the Keychain. See [SECURITY.md](../SECURITY.md) for the full crypto spec.

## Why iOS 17 minimum

The new MapKit SwiftUI `Map { content }` builder, `MapPolyline`, and the typed `Annotation` content shipped in iOS 17. The pre-iOS-17 `Map(coordinateRegion:)` API is missing the building blocks for what we want (overlaid polylines for trips, custom annotations for visits, dynamic camera control). iOS 17 also gives us `.presentationDetents` improvements that make the bottom drawer feel native.

iOS 17+ is acceptable adoption-wise as of 2026.

## JSON ingest reality check

`JSONDecoder` does **not** stream. `decode(_:from:)` requires `Data`. For an 11 MB Takeout file this works fine — read once into `Data`, decode once.

For larger files (think multi-hundred-MB Takeouts from heavy users), the importer will fall back to a custom top-level-array splitter:

1. Open `InputStream`, find the outermost `[`.
2. Track brace depth byte-by-byte to yield each top-level element's byte range.
3. Hand each element's `Data` slice to `JSONDecoder` separately.

This isn't free from Foundation, but it's ~100 lines of plain Swift and avoids pulling in a streaming JSON library (which would dilute the "Apple-only frameworks" promise).

## Network policy

The app should never make a network call outside of Apple's own SDKs (`MapKit`, `CLGeocoder`, `MKLocalSearch`). Enforcement layers, from outermost in:

1. **Info.plist** — `NSAppTransportSecurity.NSAllowsArbitraryLoads = NO`.
2. **No 3rd-party packages** — only local SwiftPM packages and (eventually) `GRDB.swift/SQLCipher`. CI rejects PRs that add network-capable dependencies.
3. **CI grep** — any `URLSession` / `URLSessionConfiguration` / `NWConnection` in app code triggers a CI failure unless it's in a small allowlisted file.

## Things deliberately left out (for now)

- **Background location ingestion.** A future feature. Requires `NSLocationAlwaysAndWhenInUseUsageDescription` and care around the encrypted DB being unavailable while the device is locked.
- **Photo-EXIF location import.** Easy add later; needs `NSPhotoLibraryUsageDescription`.
- **iCloud sync.** Out of scope for v1. If/when it returns, it will be opt-in, end-to-end encrypted (encrypt on-device before upload), and documented as a separate threat model.
- **Watch app, widgets, complications.** Possible later.
- **Web companion.** If it happens, it shares the JSON schemas in `docs/data-formats/` and nothing else.
