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

## Why SQLCipher directly (and not GRDB or Core Data)

We considered four storage stacks:

1. **Core Data** with `NSPersistentStoreFileProtectionKey = .complete`.
   File-level protection only — when the device is unlocked, the file is plaintext on disk. The threat we care about (forensic readout of an unlocked, backgrounded app) is not covered.

2. **CryptoKit-encrypted blob files** (one big AES-GCM blob per "day" of events).
   Encryption ✅, but no query layer. Filtering visits by date range, joining to places, paginating a timeline — all become custom code over deserialized blobs. Doesn't scale.

3. **GRDB.swift + SQLCipher** (the original plan).
   Full GRDB API + page-level AES-256-CBC encryption. The problem: GRDB's official SwiftPM `Package.swift` ships the SQLCipher integration as **commented-out lines** that the consumer must un-comment by forking. Community forks (DuckDuckGo's) ship as opaque precompiled xcframeworks that bundle both GRDB and SQLCipher together — auditable but indirect. Neither is a clean SwiftPM-consumer experience.

4. **`sqlcipher/SQLCipher.swift` directly + a thin Swift wrapper** *(chosen)*.
   The official SwiftPM package from the SQLCipher maintainers (Zetetic LLC) ships SQLCipher as a precompiled xcframework with `SQLITE_HAS_CODEC` enabled. We layer ~250 lines of audited Swift on top (`SQLCipherDatabase`, `PreparedStatement`, `Schema`, `Migrations`, `EventWriter`) for the operations the app actually needs.

**Why we picked #4 over #3**: less supply-chain (one upstream maintainer instead of two), tighter audit surface (a privacy-paranoid user can read the entire DB layer in one sitting), no fragile fork dependency. The tradeoff is that we don't get GRDB's nice observation API for free — if/when we need it, we can either revisit GRDB once their SwiftPM SQLCipher story improves, or grow our wrapper.

We pass SQLCipher a raw 32-byte key (`PRAGMA key = "x'<hex>'"`), not a passphrase. The key comes from `SecRandomCopyBytes` and lives in the Keychain. See [SECURITY.md](../SECURITY.md) for the full crypto spec.

### Schema in one glance

```
events                  (id PK, kind, start_ts, start_tz_offset_min,
                         end_ts, end_tz_offset_min, source, imported_at)
activities              (event_id PK→events, start_lat/lon, end_lat/lon, distance_m, mode, probability)
visits                  (event_id PK→events, place_id, lat, lon, semantic_type, hierarchy_level, probability)
path_points             (event_id+seq PK→events, offset_min, lat, lon)
places                  (place_id PK, user_label, resolved_label, resolved_at, lat, lon)

-- schema v2 (alpha: path refinement)
path_points_original    (event_id+seq PK→events, offset_min, lat, lon)
path_refinements        (event_id PK→events, refined_at, source, route_name, transport_type,
                         similarity_*_m, expected_*, candidate_count, chosen_index, *_point_count)
path_refinement_skips   (event_id PK→events, checked_at, reason)
```

`path_points` uses `(event_id, seq)` rather than `(event_id, offset_min)` as PK — real-world Takeout data has multiple GPS samples within the same minute (`offset_min` is rounded), so a unique constraint on it would reject ~5% of paths.

Schema v2 adds the alpha "path refinement" tables: the first time a refinement is applied to a trip, the existing `path_points` rows are copied into `path_points_original` (INSERT OR IGNORE — first apply wins), then `path_points` is overwritten with the chosen candidate route's coordinates. An audit row in `path_refinements` records the similarity score + source. Revert restores from `path_points_original` and drops both the snapshot and the audit row.

### Real-data sanity check

The `EndToEndImportTests` test wires the entire pipeline: decode the user's actual 11MB Takeout → write into an encrypted DB → query counts. On a 2024 M-series MacBook the timings are:

| Step                              | Time     |
|-----------------------------------|----------|
| Decode 16,732 events from JSON    | ~4.6s    |
| Insert into encrypted SQLite      | ~0.19s   |
| Total                             | ~4.8s    |

Encryption is essentially free at this scale.

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

The app should never make a network call outside of Apple's own SDKs (`MapKit`, `CLGeocoder`, `MKLocalSearch`, `MKDirections`) by default.

`MKDirections` is opt-in behind the **Alpha features** Settings toggle (off by default) — it backs the path-refinement debug screen, which asks Apple Maps for the route it would suggest for a recorded trip. Endpoints are rounded to 4 decimals (~11 m) before the request goes out, and only the coarse transport bucket (`walking` / `automobile`) accompanies the call.

`MKDirections` does **not** return transit polylines via its public API — confirmed by Apple DTS in [Apple Developer Forum 663624](https://developer.apple.com/forums/thread/663624). Transit trips are skipped when the Apple provider is selected; we never silently re-route a transit trip as driving.

Within the alpha section, the user can switch the routing provider to **Google Directions API**. That requires:
- A second, provider-specific disclosure sheet on first selection.
- A user-pasted API key — the app never ships with one; the build is portable to other users without leaking the developer's billing.
- An HTTPS call to `maps.googleapis.com/maps/api/directions/json` with rounded endpoints, the coarse mode, and the user's key.

Strict ATS (`NSAllowsArbitraryLoads = NO`) covers both providers — both use TLS. See [PRIVACY.md](../PRIVACY.md#alpha-features-path-refinement) for the per-provider data tables. Enforcement layers, from outermost in:

1. **Info.plist** — `NSAppTransportSecurity.NSAllowsArbitraryLoads = NO`.
2. **No 3rd-party packages** — only local SwiftPM packages and (eventually) `GRDB.swift/SQLCipher`. CI rejects PRs that add network-capable dependencies.
3. **CI grep** — any `URLSession` / `URLSessionConfiguration` / `NWConnection` in app code triggers a CI failure unless it's in a small allowlisted file.

## Things deliberately left out (for now)

- **Background location ingestion.** A future feature. Requires `NSLocationAlwaysAndWhenInUseUsageDescription` and care around the encrypted DB being unavailable while the device is locked.
- **Photo-EXIF location import.** Easy add later; needs `NSPhotoLibraryUsageDescription`.
- **iCloud sync.** Out of scope for v1. If/when it returns, it will be opt-in, end-to-end encrypted (encrypt on-device before upload), and documented as a separate threat model.
- **Watch app, widgets, complications.** Possible later.
- **Web companion.** If it happens, it shares the JSON schemas in `docs/data-formats/` and nothing else.
