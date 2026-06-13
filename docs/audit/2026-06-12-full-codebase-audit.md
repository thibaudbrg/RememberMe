# RememberMe full-codebase audit — 2026-06-12

> **Fix status (same day):** all findings below were fixed except the following deliberate exceptions.
> - **L3** — `sqlite3_key_v2` is not exposed by the prebuilt SQLCipher Swift package (`SQLITE_HAS_CODEC` guard); needs a C-shim target or dependency build-config change. The key still transits `PRAGMA key`.
> - **M1 / M3** — fixed as documentation corrections: the biometric-bound Keychain item and the in-app "Wipe all data" feature were *not* implemented (product decisions); PRIVACY.md/SECURITY.md now describe actual behavior.
> - **L12** — `'localtime'` day bucketing kept as-is (deliberate); the TZ-dependent test was pinned instead (M35).
> - **L24** — MotionAggregator still votes per update; only the deterministic tie-break (L63) landed.
> - **L33** — AppEnvironment was not split wholesale; the targeted extractions (L34/L35/L37/L39) landed.
> Verification: Core 124 tests green, Persistence 76 tests green, app builds for iOS, app tests green on simulator.

**Method.** 14 specialized review agents each swept one dimension of the working tree (crypto, privacy/config, SQL, concurrency, geo algorithms, tracking pipeline, refinement, SwiftUI, encapsulation/dead code, error handling, importer, lifecycle/leaks, platform API, tests). Every finding was then re-read by an independent adversarial verifier instructed to refute it; only findings the verifier confirmed in the actual code appear below. Raw counts: 151 findings → 144 confirmed, 7 refuted (refutations documented at the end).

**Severity scale.** Critical = data loss/security breach/crash in normal use · High = real bug likely to bite · Medium = incorrect-but-survivable / leaky encapsulation / confirmed dead code · Low = genuine imperfection worth knowing.

No critical findings. After merging cross-dimension duplicates: **13 high, ~37 medium, ~63 low**.

---

## Root-cause themes

1. **One shared SQLCipher connection, transactions from many threads.** `SQLITE_OPEN_FULLMUTEX` serializes individual C calls, not transaction scope. The live tracker, importer, geocoder and refinement all write concurrently → "cannot start a transaction within a transaction" failures, silently dropped GPS batches, writes silently joining foreign transactions. (H1, M-SQL-3, M-CON-1)
2. **PRIVACY.md / SECURITY.md promise properties the code doesn't implement** — biometric key binding, wipe-all-data, "on-demand" geocoding, log rounding, xcconfig enforcement. Either implement or correct the docs. (M-DOC-*)
3. **The import pipeline is neither idempotent nor resilient** — re-import duplicates the whole history; one malformed record aborts everything; a mid-import failure leaves a committed partial import that "Try again" duplicates. (H5, M-IMP-*)
4. **Precise location data leaks into the unified system log** in all builds, contradicting the documented threat model. (H3)
5. **The refinement feature shares one controller with no fetch identity/cancellation** — stale candidates can be applied to the wrong trip; transient network errors permanently burn trips from batch runs. (H7, H8, M-REF-*)
6. **Background-relaunch tracking is broken at the Keychain layer** — the DB file protection was relaxed for it, but the key class wasn't. (H2)

---

## High severity

### H1. Cross-thread transactions on the single SQLite connection lose data
`Packages/Persistence/Sources/Persistence/SQLCipherDatabase.swift:135` · `RememberMe/RememberMe/Features/Tracking/LocationTracker.swift:358,406`
*(merged: sql + concurrency ×2 + tracking findings)*

`transaction()` issues `BEGIN IMMEDIATE`/`COMMIT` on the one shared connection, while the app deliberately uses it from many threads at once: `finaliseTrip()` spawns two back-to-back `Task.detached` (point flush `appendPoints` — itself a transaction — and `updateEnd` + `writeActivity`, also a transaction) that race **on every trip close with pending points**; Takeout import, encrypted restore, refinement applies and geocoder upserts add more. Consequences confirmed in code:
- Second concurrent `BEGIN IMMEDIATE` → throws; `flushPendingPoints` already cleared its buffer and bumped `nextSeq` before the write, so up to 5 GPS points are **permanently lost, only logged**.
- A failed `writeActivity` leaves the trip an orphan; recovery degrades it to `mode="unknown"`, discarding classification and distance.
- A single-statement write executed between another thread's `BEGIN` and `ROLLBACK` silently joins that transaction and can be rolled back with it — invisible data loss. Same-connection readers observe uncommitted mid-transaction state.
- The `@unchecked Sendable` justification comment (lines 34–37) and the "cross-thread access is safe" comment in `TrackingQueries.swift:11-13` are both wrong as stated.

**Fix.** Add a private `NSRecursiveLock` to `SQLCipherDatabase`: hold it across the entire `transaction()` body and around every single-statement write path; additionally chain `LocationTracker`'s DB writes through one serial `persistChain` task instead of independent `Task.detached`, and restore `pointsToWrite` to the buffer when a flush fails.

### H2. DB key Keychain class breaks background-relaunch tracking
`Packages/Core/Sources/Core/Crypto/KeychainKeyStore.swift:83`

The key is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, but the DB file was deliberately relaxed to `.completeUntilFirstUserAuthentication` so background location callbacks can write, and `AppDelegate` exists specifically to handle iOS relaunching the terminated app for SLC/visit events. On a locked-device relaunch (phone in pocket — the normal case), `SecItemCopyMatching` returns `errSecInteractionNotAllowed`, `fetchKey()` throws, `ensureOpen()` silently sets `importStatus = .failed`, the tracker is never re-armed (`tripWriter` stays nil) and **every fix from that background session is dropped**. The file-protection half of the migration was done; the Keychain half was missed (the class doc comment still says "Pairs with NSFileProtectionComplete").

A second verifier (errors dimension) confirmed the failure is also **never retried**: `ensureOpen()`'s only other callers are the foreground `.task` and user-initiated import/export; the `scenePhase == .active` handler does not call it, no `protectedDataDidBecomeAvailable` observer exists, and the tracker never re-requests a bind — so a single keychain failure silently drops the entire tracking session until the user manually foregrounds the app (a process that can live for days).

**Fix.** Switch to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` *and* migrate existing items via `SecItemUpdate` from an unlocked launch path (accessibility is fixed at `SecItemAdd` time). Defense-in-depth: observe `protectedDataDidBecomeAvailable` (or retry open from location callbacks when `database == nil`). Update KeychainKeyStore doc comment, SECURITY.md:46,56, PRIVACY.md:10,65,68.

### H3. Full-precision location data persisted to the system log in all builds
`RememberMe/RememberMe/Features/Tracking/LocationTracker.swift:699,731` · `RememberMe/RememberMe/Features/Map/GeocodingService.swift:180,192,218`

Every background GPS fix and CLVisit is logged at `.notice` with raw lat/lon interpolated as Doubles (numeric values are **public by default** in OSLog and `.notice` persists to disk). The geocoder logs resolved street addresses/POI names with an explicit `privacy: .public`, and raw coordinates on failure. Net: a continuous plaintext movement trail + visited-address list accumulates in the unified log (Console on a paired Mac, sysdiagnoses, log archives), outside the SQLCipher DB — directly contradicting PRIVACY.md line 13 ("production builds round coordinates to ~1 km").

**Fix.** Annotate all coordinate/address interpolations `privacy: .private` (or round to 2 decimals to match the doc), drop `.public` from placemark fields and error descriptions; gate full precision behind the documented (but currently unreferenced) `VERBOSE_LOGGING` flag.

### H4. Encrypted export/restore drops refinement state — restored backups resurrect superseded trips
`Packages/Persistence/Sources/Persistence/ExportQueries.swift:151`

`fetchExportedEvents` only selects v1 columns: `is_superseded`, `derived_from_event_id` and the `path_refinements` / `path_points_original` / `path_refinement_skips` tables are never exported; restore inserts defaults (`is_superseded=0`). Restoring a backup after any multi-leg/journey refinement shows every superseded original **next to** its derived legs: duplicate trips/visits, double-counted distance, and the revert lineage is permanently lost.

**Fix.** ExportPayload v2: add `isSuperseded`/`derivedFromEventID` (decode-with-default keeps v1 files parsing), include in SELECT + INSERT. Minimum to stop visible duplicates: round-trip `is_superseded` alone.

### H5. Re-importing the same Takeout file duplicates the entire history
`Packages/Persistence/Sources/Persistence/EventWriter.swift:40` · `Packages/Core/Sources/Core/Importers/GoogleTakeoutDecoder.swift:115` *(merged: sql + importer)*

Event IDs are freshly random per decode (`Event.id` defaults to `UUID()`; the decoder never supplies one), `EventWriter` uses plain `INSERT`, and the schema has no natural-key uniqueness. "Import Google Takeout" is always available in Settings, so importing twice — or importing a newer overlapping export — silently doubles every visit, activity, path point, distance and insight, with no undo. (Contrast: `ExportQueries.restore` deliberately uses `INSERT OR IGNORE`.)

**Fix.** Derive deterministic UUIDv5 IDs in the decoder from `source|kind|start|end|payload-digest`, switch EventWriter to `INSERT OR IGNORE`, and skip child rows when `changes() == 0`. (Alternative: unique index on `(source, kind, start_ts, end_ts)` + migration.)

### H6. `.stationary` is a background trap state — the trip after a stop is missed
`RememberMe/RememberMe/Features/Tracking/LocationTracker.swift:711` (runtime gate at ~780) · `TrackerState.swift:258-260`

The state machine defines `(.stationary, .significantLocationChange) → .waking`, but the runtime only feeds SLC events when `state == .deepSleep`. In `.stationary`, GPS is disarmed, the app suspends, the 15-min deep-sleep timer freezes, and motion updates stop. When the user moves again, the SLC wake fires with `state == .stationary` and is **silently dropped**; the app re-suspends. Only a (often 5–20 min late, sometimes absent) CLVisit departure escapes. Net: after any trip ending via the 180 s stationary timer in background, the next trip is unrecorded or starts very late.

A platform-dimension verifier confirmed the suspension mechanics independently: `.stationary`'s entry actions disarm full GPS and set `allowsBackgroundLocationUpdates = false`; SLC/visit monitoring alone does not keep an app running, so iOS suspends the process within seconds — freezing the 15-minute `Timer.scheduledTimer` and stopping CMMotion delivery, which are the state's other two exit paths.

**Fix.** `if state == .deepSleep || state == .stationary {` at the SLC gate. Hardening: persist the deep-sleep deadline as wall-clock and check it lazily on any wake instead of relying on a Timer that can't fire while suspended.

### H7. Re-applying a refinement leaves stale derived legs — duplicate trips
`Packages/Persistence/Sources/Persistence/RefinementQueries.swift:292`

No apply function deletes derived events from a previous apply (`DELETE FROM events WHERE derived_from_event_id = ?` exists only in revert). The UI makes re-apply trivially reachable (detail view resets to `.idle` with the Fetch button even when `isRefined`). Applying multi-modal candidate A then candidate B → leftover legs from A render alongside B's, covering the same time window, until a manual revert.

**Fix.** At the start of each apply transaction, delete prior derived events for the target (cascade removes children); in `applyRefinement` also un-supersede prior journey member IDs from the audit row.

### H8. Batch refinement permanently burns trips on transient failures; Google throttling never engages back-off
`RememberMe/RememberMe/Features/Refinement/RefineHistoryProgressSheet.swift:391` · `GoogleDirectionsRouter.swift:81` *(related pair)*

`applyBestOrSkip` falls through to `markSkipped(.noCandidates)` for **any** non-`.ready` state — network loss, missing API key, even DB write failures. Skip rows persist, are excluded from all future runs, and have no clearing UI: losing connectivity for a minute during "Refine entire history" permanently skips every trip touched in that window (~0.1–0.4 s per trip). Compounding it, Google's `OVER_QUERY_LIMIT` throws `.other("Google API quota exceeded.")`, which doesn't match the `"rate-limit"` sentinel string, so `ThrottlePolicy.google`'s back-off is unreachable dead config — quota exhaustion mid-run marches through the remaining history at 10 QPS marking everything skipped.

**Fix.** Type the failure (`lastError: RoutingError?` on the controller); only persist skips for genuine no-route outcomes; retry/back-off on `.network`/throttle; abort on `.missingAPIKey`/DB errors. Map `OVER_QUERY_LIMIT` to a throttled error case whose description carries the sentinel (or better, replace the string sentinel with a typed check).

### H9. Photo thumbnails hang forever for iCloud-offloaded assets, leaking continuations
`RememberMe/RememberMe/Features/Photos/PhotoLibraryService.swift:147` *(merged: lifecycle + concurrency)*

`thumbnail(for:size:)` ignores every degraded callback inside `withCheckedContinuation`, but with `isNetworkAccessAllowed = false` an iCloud-offloaded asset ("Optimize iPhone Storage" — the default) delivers **only** the degraded local thumbnail. The continuation never resumes: permanent placeholder/spinner, and one leaked task + continuation per appearance (task cancellation can't free it — the continuation isn't cancellation-aware, and the `PHImageRequestID` is discarded).

**Fix.** Read `PHImageResultIsInCloudKey` and resume with the degraded image when no final callback can come (`if isDegraded && !isInCloud { return }`). Follow-up: wrap in `withTaskCancellationHandler` + `cancelImageRequest`.

### H10. Biometric lock never re-engages after backgrounding; history visible in the app switcher
`RememberMe/RememberMe/App/RootView.swift:15`

The lock gates on a `@State` flag set true once per process and never reset; no scene-phase handler obscures the UI. With the lock enabled, unlock once and the app stays unlocked for the process lifetime (suspension, not termination, is the normal lifecycle), and the app-switcher snapshot shows the map/timeline to anyone swiping through. The "lock" only protects cold launches.

**Fix.** `.onChange(of: scenePhase)`: reset `hasUnlocked` when leaving `.active` — this also swaps `LockedView` in before iOS takes the snapshot. Optionally a grace period.

### H11. Tracker auto-escalates to Always authorization from every When-In-Use grant
`RememberMe/RememberMe/Features/Tracking/LocationTracker.swift:689`

`locationManagerDidChangeAuthorization` escalates unconditionally — including when the user grants When-In-Use via the map's separate locate-me flow, and at every cold launch for When-In-Use users. iOS shows the "Change to Always Allow?" upgrade prompt **once per install**; burning it on an out-of-context moment means the real Live-Tracking enable flow can never prompt again (silent no-op; Settings is the only path left).

**Fix.** Gate escalation behind a `pendingAlwaysEscalation` flag set only by the tracker's own `requestAlwaysAuthorization()` flow.

### H12. The encrypted backup/restore path has zero tests — and inspection already shows it loses data
`Packages/Persistence/Sources/Persistence/ExportQueries.swift:8,23`

`fetchExportPayload` and `restore` are the app's only backup/recovery path, and no test in PersistenceTests touches either (grep confirms). Untested consequences visible by inspection: the superseded/derived-state loss documented in H4, and a NULL-unsafe scalar `MAX` in the places upsert. For a feature whose entire job is "don't lose the user's history", this is the most dangerous coverage gap in the codebase.

**Fix.** Round-trip test: populate a DB (including a refined trip), export, restore into a fresh DB, diff. That test immediately catches H4; fix the places upsert with a NULL-safe MAX while there.

### H13. The 844-line live-tracker runtime has zero tests; the app target's only test is `XCTAssertTrue(true)`
`RememberMe/RememberMe/Features/Tracking/LocationTracker.swift` · `RememberMe/RememberMeTests/RememberMeTests.swift:6`

The live tracker is the only source of *new, unrecoverable* user data (Takeout can be re-imported; live trips cannot), yet `beginTrip`/`appendFix`/`flushPendingPoints`/`finaliseTrip`/the visit lifecycle have no tests at all — the state machine and writer are tested in isolation, but none of the orchestration (which is where H1, M13, M19 live). The app target's sole test passes unconditionally, so the scheme is green no matter what regresses.

**Fix.** Extract the OpenTrip buffer/flush/finalise sequencing into a testable type (or use `@testable`) and drive `LiveTripWriter` against an in-memory DB, asserting seq continuity, flush-then-finalise ordering, and the failure/re-queue path. Replace the vacuous app test (PhotoCluster.cluster is pure geometry begging for tests).

---

## Medium severity

### Security & privacy

- **M1. Face ID lock is a UI curtain; docs claim cryptographic binding.** `KeychainKeyStore.swift:80`, `RememberMeApp.swift:15`. SECURITY.md:51-59 describes a `SecAccessControlCreateWithFlags([.biometryCurrentSet, .or, .devicePasscode])` item recreation that exists nowhere; PRIVACY.md:71 claims re-prompt "before unwrapping the key", but `ensureOpen()` unconditionally fetches the key and decrypts the DB before `LockedView` is evaluated. Fix the docs (minimal) or implement the gate — noting it conflicts with background launches that need the key without UI.
- **M2. Malicious `.rmex` import can crash or jetsam the app.** `ExportEnvelope.swift:116`. Header `m/t/p` Argon2 params are attacker-controlled (the AAD authenticates a constant string, *not* the header — SECURITY.md:89's downgrade-protection claim is false) and flow into trapping `UInt32` conversions / multi-GB allocations. Fix: bounds-check (`m` 8 MiB–512 MiB, `t` 1–16, `p` 1–4) before deriving; v2 format should AAD the header bytes.
- **M3. Documented "Wipe all data" doesn't exist.** PRIVACY.md:80, SECURITY.md:93-103 spec `wipeEverything()` step by step; no wipe row exists in Settings and `KeyStore.deleteKey()` has no production caller. Implement or correct docs (+ onboarding copy "yours to keep or wipe").
- **M4. Google Directions API key in plaintext UserDefaults, included in backups.** `Settings.swift:79`. A billing-bearing credential in an unencrypted, backed-up plist — contradicting the project's own in-scope threat "backup leakage". Fix: Keychain item (reuse KeychainKeyStore pattern) + one-time migration off UserDefaults.
- **M5. Geocoding is automatic and bulk, not "on-demand when you tap a visit".** `RememberMeApp.swift:25` (+ `AppEnvironment.swift:331,581`). Up to 200 full-precision visited-place coordinates stream to Apple per run on every foreground/open/import, no opt-out — PRIVACY.md:22 and the Info.plist claim are false as written.
- **M6. Info.plist purpose strings make absolute claims the code contradicts.** `Info.plist:34` — "Nothing leaves your iPhone" / "never sent anywhere" vs. CLGeocoder + refinement traffic. Misleading purpose strings are also an App Review risk. Reword.
- **M7. Google/alpha consent sheets are swipe-dismissable; acknowledgment never gates requests.** `SettingsSheet.swift:129,217` (+ `GoogleConfirmationSheet.swift:58`, `PathRefinementController.swift:78-92`). The provider flips **before** consent; swipe-down leaves it on Google with `googleRoutingAcknowledged == false`, and no call site checks the flag. Fix: `onDismiss` revert-unless-acknowledged on both sheets; defense-in-depth guard in the controller's `.google` branch.
- **M8. PRIVACY.md "audit this yourself" section fails its own audit.** PRIVACY.md:108. The xcconfig isn't wired into the build (no `baseConfigurationReference`), the zero-`URLSession` grep claim is contradicted by `GoogleDirectionsRouter`, and the ATS claim overstates what ATS does (HTTPS exfiltration is unaffected).

### Persistence & data correctness

- **M9. `PreparedStatement.step()` swallows every SQLite error into `.done`.** `PreparedStatement.swift:55`. Every `while stmt.step() == .row` loop silently truncates on error (empty map/timeline, silently truncated exports); `userVersion()` returning 0 on error would re-run Schema v1 on an existing DB. Fix: make `step()` throw; update ~45 call sites (mostly mechanical).
- **M10. Insights double-count refined trips.** `InsightsQueries.swift:66,92,117,145` ignore `is_superseded` — distance/duration roughly doubles for every refined trip.
- **M11. Events spanning midnight vanish from the second day.** `DayQueries.swift:83,121,173,235,305,322` filter `start_ts` only. The most common record in the app — the overnight home visit — never appears on the morning day. Fix: overlap predicate (`start_ts < :end AND end_ts > :start`, keeping live placeholder rows); same in `RefinementQueries.swift:576,582,614`.
- **M12. `transaction()` leaves the connection in an open transaction if COMMIT fails.** `SQLCipherDatabase.swift:144`. Everything fails with "cannot start a transaction within a transaction" until restart. Fix: ROLLBACK-on-COMMIT-failure.
- **M13. Visit departure UPDATE can run before arrival INSERT.** `LocationTracker.swift:488` — independent `Task.detached` with no ordering; zero-row UPDATE succeeds silently → permanent zero-duration visit. Fix: the same serial persist chain as H1; check `sqlite3_changes()`.

### Concurrency & responsiveness

- **M14. Stale refinement fetches clobber the shared controller — wrong trip's routes applied.** `PathRefinementTripDetailView.swift:95,188` + `PathRefinementController.swift:110,248` *(merged ×3: concurrency, refinement, lifecycle)*. `fetch` is re-entrant, never cancelled, never checks `activeTripID` (which is written but **never read** anywhere). Trip A's late completion pushes A's candidates into trip B's compare view; Apply persists A's polyline onto B. Fix: generation counter / `activeTripID` guard before every terminal state write; clear `activeTripID` in the sheet's `onDismiss`.
- **M15. `exportEncrypted` materializes the entire DB synchronously on the main actor.** `AppEnvironment.swift:611`. Seconds-long UI freeze on large histories (watchdog risk). Move the fetch into the existing detached task, as `importEncrypted` already does.
- **M16. `loadDay` decodes every path point in range on the main thread.** `AppEnvironment.swift:404`. Month view + dense tracker data = 10⁵+ rows per tap. Fix: off-main read connection (actor) or stride-sampling at query time for week/month.

### Tracking correctness

- **M17. Motion permission denial strands the tracker in `.waking` with background GPS running forever.** `LocationTracker.swift:546` + `TrackerState.swift:240-245`. Authorization is never checked, errors aren't handled, and `.waking` has no timeout — maximum battery drain while recording nothing. Fix: `wakingProbeTimedOut` input (~60 s) → `.stationary`; log denied motion permission.
- **M18. `automotive+stationary` motion samples close the trip after 3 minutes of stopped traffic.** `LocationTracker.swift:573`. Apple documents the combined flags; checking `stationary` first splits one drive into multiple trips with gaps. Fix: check moving bits first (matches the code's own comment).
- **M19. CLVisit with unknown arrival writes a visit starting in year 1.** `LocationTracker.swift:725`. `arrivalDate == .distantPast` (documented for first-departure-after-monitoring-starts) is written raw as `start_ts`. Fix: clamp to departure.

### Refinement logic

- **M20. Journey apply supersedes absorbed edge visits with nothing replacing them.** `PathRefinementController.swift:308` + `Journey.swift:57-69`. A leading/trailing sub-10-min visit is superseded but outside the derived legs' time window — it disappears from the timeline until a full revert. Fix: trim non-activity entries from both ends in `JourneyDetector.detect`.
- **M21. Week/month batch runs do all the work in the first "day" iteration.** `RefineHistoryProgressSheet.swift:291`. `selectDay` loads the whole `dayRange` while the range picker is on week/month — progress/ETA are fiction and each trip reloads the full range. Fix: force `.day` granularity for the run, restore after.

### SwiftUI & performance

- **M22. The full polyline render plan recomputes (twice) per body evaluation.** `MapScreen.swift:240`. `tripRenders` and `directionMarkers` both run the O(activities × paths × samples) pipeline inside the Map content builder on every camera-gesture end. Fix: compute once where `dayTrips`/`dayPathTraces` are assigned, store on AppEnvironment.
- **M23. `onChange(dayMarkers/dayPhotos)` recenters unconditionally, discarding active focus.** `MapScreen.swift:51-53`. Tap a visit → geocode resolves → refresh() → camera snaps back out while the detail sheet is up. Fix: use `reapplyCamera` (already focus-aware).
- **M24. `jumpToVisit` focus is wiped by the sheet's `onDismiss` `clearFocus`.** `MapScreen.swift:67` + `PlaceDetailView.swift:189-201`. Racy: whichever finishes last wins. Fix: one-shot `suppressNextFocusClear()`.
- **M25. Journey "Try again" after a failed fetch refetches the single trip, not the journey.** `PathRefinementTripDetailView.swift:237`. Apply then targets the wrong scope. Fix: mirror the `if let journey` branch.
- **M26. Eager timeline VStack runs `hasNearbyPhoto` (O(photos)) per row, rebuilt every 1.2 s during geocoding.** `TimelineDrawerContent.swift:429` + `AppEnvironment.swift:240-266`. Fix: precomputed `Set<TimelineEntry.ID>` + skip reassignment when the refreshed timeline is equal.

### Architecture & importer

- **M27. The batch-refinement engine lives inside a SwiftUI View, queries SQL directly, and iterates by mutating global `selectedDay`.** `RefineHistoryProgressSheet.swift:433` (+ 108, 237). Untestable, scrubs the whole UI as a side effect, pokes controller internals. Fix: extract a `@MainActor @Observable` runner that takes days explicitly.
- **M28. Whole Takeout file decoded in memory — multi-hundred-MB imports get jetsam-killed.** `AppEnvironment.swift:566` + `GoogleTakeoutDecoder.swift:57`. Peak memory is several × file size (tree-based JSONDecoder + Wire array + Event array all resident). Fix: `.mappedIfSafe` read + depth-1 streaming record scanner with batched writes.
- **M29. One malformed record aborts the entire import.** `GoogleTakeoutDecoder.swift:57` + non-optional `GoogleTakeoutWire` fields. The per-record skip machinery only runs *after* the full array decodes; Google has changed this format repeatedly. Fix: lossy per-element wrapper routing schema mismatches into the existing `SkipReason` flow.
- **M30. Mid-import failure leaves a committed partial import; "Try again" duplicates it.** `EventWriter.swift:25`. Independent per-chunk transactions, no session marker, IDs regenerate per decode. Fix: one outer transaction (or `DELETE ... WHERE imported_at = ?` cleanup on error).
- **M31. LocateMeManager starts continuous best-accuracy GPS at app launch and never stops.** `LocateMeButton.swift:59` (+ `MapScreen.swift:21`) *(merged: lifecycle + swiftui)*. The legacy delegate callback fires on creation with existing authorization → GPS runs the whole foreground session without any tap. Fix: one-shot `requestLocation()` + `pendingRequest` flag.
- **M32. One shared CLGeocoder serves the background trickle and on-demand lookups concurrently.** `GeocodingService.swift:22,211` *(merged with low dup)*. CLGeocoder handles one request at a time; the second cancels the first (`kCLErrorGeocodeCanceled`) exactly when users browse places post-import. Fix: fresh `CLGeocoder` per request.
- **M33. `markSkipped` swallows write errors with `try?`, enabling an infinite request loop in the history runner.** `PathRefinementController.swift:352-355`. The skip row is the only thing that makes `runOneDay` progress past an unrefinable trip; if the INSERT fails (disk full), `pickNextRefinable` returns the same trip forever and the runner hammers the routing API in a loop. Fix: keep a local `attempted` set in `runOneDay` so each trip is fetched at most once per run regardless of skip-write success.
- **M34. Reduced-accuracy authorization is unhandled — Precise Location off silently records nothing.** `LocationTracker.swift:793` (65 m gate). Nothing reads `accuracyAuthorization` or requests temporary full accuracy; with Precise Location off, fixes arrive at 1–5 km accuracy and the gate discards 100 % of them — trips open and close but no activity row is ever written, with no user-facing warning. Fix: surface a "Precise Location is off" banner in LiveTrackingSection and/or request temporary full accuracy.

### Test-quality findings (verified on Opus 4.8)

- **M35. `fetchDaysWithData` test fails in UTC+9…+12 timezones — reproduced by running under `TZ=Asia/Tokyo`.** `DayQueriesTests.swift:108`. The production query groups by `'localtime'` (see L12), so the 12:00Z/15:00Z fixtures land on different local days east of UTC+9. Fix: pin TZ in the test (and consider making the query take an explicit TimeZone).
- **M36. Migrations are never tested against a populated older-version database.** `Migrations.swift:18`. Every test opens a fresh DB and runs the full v1→v4 chain on empty tables; the real upgrade scenario (v3 `ALTER TABLE` on a live `events` table at app update) has zero coverage, and the migration test comment is stale (claims v2; schema is at v4). Fix: build a v1/v3 DB with rows, apply, assert data survives and new columns default correctly.
- **M37. Re-import duplication (H5) is unspecified by any test.** `EventWriterTests` never write the same decoded events twice. A duplicate-import test would have caught H5 before it shipped.
- **M38. KeychainKeyStore tests skip everywhere except macOS — the iOS data-protection-keychain branch guarding the DB key is never executed by any test.** `KeychainKeyStoreTests.swift:16` vs `KeychainKeyStore.swift:53-55` (`kSecUseDataProtectionKeychain` is `#if os(iOS)`). Fix: run the round-trip test in the iOS-simulator app test target.

---

## Low severity (condensed)

### Crypto
- **L1.** `ExportEnvelope.open` never verifies `header.aad` equals the expected constant — domain separation is a no-op. `ExportEnvelope.swift:128`.
- **L2.** SECURITY.md:33 claims `NSFileProtectionComplete`; code applies `completeUntilFirstUserAuthentication`. Doc fix.
- **L3.** Raw SQLCipher key passes through the SQL tokenizer via `PRAGMA key` in an unzeroizable Swift String. Prefer `sqlite3_key_v2`. `SQLCipherDatabase.swift:61`.
- **L4.** First-launch race in `getOrCreateKey`: `errSecDuplicateItem` treated as fatal instead of re-fetching the winner's key. `KeychainKeyStore.swift:85`.
- **L5.** WAL/SHM sidecars not excluded from backup despite PRIVACY.md's no-backup claim. `DatabaseFactory.swift:21`.
- **L6.** Export accepts a 1-character passphrase; no strength floor. `SettingsSheet.swift:198`.

### Privacy/config
- **L7.** `UIFileSharingEnabled` + open-in-place expose Documents (plaintext Takeout files) via Finder/Files; the only consumer is DEBUG-only. `Info.plist:51`.
- **L8.** PRIVACY.md:23 discloses MKLocalSearch traffic; no search feature exists in code.
- **L9.** `VERBOSE_LOGGING` is documented as the precise-coordinate gate but referenced by zero Swift files. `Config.example.xcconfig:17`.

### SQL
- **L10.** All-time queries (`fetchRecentTrips`, `fetchTimeline`, `fetchVisitHistory`, `VisitMarker.fetchVisitMarkers`) omit the `is_superseded = 0` filter their day-bounded twins apply. `Queries.swift:238,298,196`.
- **L11.** NULL `expected_travel_s`/`expected_distance_m` read back as 0.0 — `columnDouble` has no NULL check. `RefinementQueries.swift:738`.
- **L12.** Day grouping uses `'localtime'` (device TZ at query time) instead of the stored per-event offsets — days shift after traveling. `DayQueries.swift:349`, `InsightsQueries.swift:147`.
- **L13.** `idx_path_points_event` duplicates the `(event_id, seq)` PK — pure write amplification on the hottest insert path. `Schema.swift:111`.

### Algorithms
- **L14.** `RouteSimilarity.score` is one-directional — candidate detours through unsampled areas are never penalized. `RouteSimilarity.swift:17`. Add a length tie-breaker rather than symmetrizing.
- **L15.** `GooglePolyline.decode` fabricates coordinates from invalid characters (`asciiValue ?? 0`, no range check) instead of rejecting. `GooglePolyline.swift:34`.
- **L16.** `RouteSimilarity.nearestPointDistance` breaks across the antimeridian (raw longitude subtraction). `RouteSimilarity.swift:52`.
- **L17.** `haversineMeters` can return NaN for near-antipodal points (missing clamp). `PolylineDirection.swift:118`.
- **L18.** Direction-marker interpolation lerps raw lon — wrong position on dateline-crossing segments. `PolylineDirection.swift:100`.
- **L19.** `Coordinate.parse(geoURI:)` accepts NaN/inf/out-of-range lat-lon despite its "nil on malformed" contract. `Coordinate.swift:20`.
- **L20.** `RefinementMode.map` misroutes granular modes it itself produces: "cable car" → automobile, "ferry" → walking. `RefinementMode.swift:28,31` *(two findings merged)*.
- **L21.** `GreatCircle.arc` emits raw atan2 longitudes — **medium-adjacent**: trans-Pacific flight arcs render as a world-spanning horizontal line (see M-list candidate; verifier graded medium under algorithms: `GreatCircle.swift:45`). Unwrap longitudes against the previous point.

### Tracking
- **L22.** Only `locations.last` is appended per callback — iOS batches multiple fixes (deferred delivery, background wake); the path is thinner than the comment claims. `LocationTracker.swift:698`.
- **L23.** Trips started before `bindPersistence` buffer points unboundedly, then FK-fail when the writer binds mid-trip. `LocationTracker.swift:344`.
- **L24.** `MotionAggregator` votes per update, not per duration — classification biased toward flickery activities. `MotionAggregator.swift:58`.

### Refinement
- **L25.** Single-trip multi-leg apply stores coarse `mode.rawValue` where journey apply stores granular `displayMode` — inconsistent downstream styling. `PathRefinementController.swift:153`.
- **L26.** Unroutable journeys re-fetched once per member trip (only the anchor gets the skip row). `RefineHistoryProgressSheet.swift:367`.
- **L27.** Journey precise-car gate's fallback reference distance uses the anchor trip, not the journey span. `RefineHistoryProgressSheet.swift:419`.
- **L28.** Four `SkipReason` cases are never written; everything lands as `no_candidates` — the ledger lies. `RefinementQueries.swift:62`.

### SwiftUI
- **L29.** O(n²) photo clustering re-runs inside `body` on every MapScreen evaluation. `MapScreen.swift:172` + `PhotoCluster.swift:42-68`.
- **L30.** `RefinementMapView.recordedSamples` (full path-sample scan) recomputes multiple times per body pass. `RefinementMapView.swift:42`.
- **L31.** CalendarSheet "Today" triggers `selectDay` twice (button task + selection onChange). `DayPickerView.swift:172`.
- **L32.** Photos toggle triggers duplicate concurrent full photo-library loads (onChange + `.task(id:)` on the same key). `SettingsSheet.swift:51`.

### Encapsulation & dead code
- **L33.** `AppEnvironment` is a 1,029-line god object mixing DB lifecycle, import, export, navigation state, photo loading and geometry heuristics. Mechanical extraction plan available in the digest. `AppEnvironment.swift:15`.
- **L34.** Write-only published state: `visitMarkers`, `recentTrips`, `timeline` are fetched on every `refresh()` and read by nothing. `AppEnvironment.swift:36`.
- **L35.** Dead accessors with zero callers: `polyline(for:)`, `recordedPath(forEventID:)`, `originalPath(forEventID:)`. `AppEnvironment.swift:802,834,978`.
- **L36.** Dead Persistence API: `fetchRefinements` (zero refs), `fetchOriginalPathPoints` (only transitively-dead caller), `skipReason` (tests only). `RefinementQueries.swift:678,631`.
- **L37.** Sample-slicing logic duplicated between `AppEnvironment.recordedSamples` and `TripRenderPlan.coordinates` — and the copies have already drifted. `AppEnvironment.swift:849`.
- **L38.** `isCarMode` duplicated byte-for-byte in `JourneyDetector` and `TripPrecision`. `Journey.swift:108`.
- **L39.** Heal threshold 1,500 m duplicated as a magic number, kept in sync by comment only. `PathRefinementController.swift:345` vs `AppEnvironment.swift:873`.
- **L40.** `TripRenderPlan.isCoveredByAnyPath` is dead, with a stale comment claiming it's still used. `TripRenderPlan.swift:101`.
- **L41.** `PolylineSmoothing.chaikin` is dead public API exercised only by its own tests. `PolylineSmoothing.swift:21` *(two findings merged)*.
- **L42.** Dead `TripStyle.polylineColor`/`pathTraceColor`. `TripStyle.swift:11`.
- **L43.** `GeocodingService.stop()` never called; epilogue would race a restarted loop if it were. `GeocodingService.swift:110` *(two findings merged)*.
- **L44.** `ContentView.swift` is an obsolete leftover (self-described legacy placeholder), referenced only by its own preview. Delete + 4 pbxproj refs.
- **L45.** App-target types (`AppEnvironment`, `Settings`, `GeocodingService`, `LocationTracker`, …) are `public` with no external consumers.

### Importer
- **L46.** Only the iOS-phone Takeout shape is supported; Android/web exports (E7 ints, numeric fields) fail wholesale with an opaque error. `GoogleTakeoutWire.swift:3`.
- **L47.** `DocumentPicker` can never deliver `.failure` — the error branches at both import call sites are dead. `DocumentPicker.swift:35`.
- **L48.** Decode failures surface as "error 0" — `DecodeError` isn't `LocalizedError`. `GoogleTakeoutDecoder.swift:35` / `AppEnvironment.swift:583`.
- **L49.** `asCopy` picker copies of multi-hundred-MB files are never deleted from tmp. `DocumentPicker.swift:22` *(two findings merged)*.
- **L50.** `"nan"`/`"inf"` strings bypass the `?? 0` fallback and abort the import via NOT NULL violation. `GoogleTakeoutDecoder.swift:133`.
- **L51.** A fresh `ISO8601DateFormatter` is allocated per timestamp (two per record) — dominates decode time on large files. `TimestampedLocal.swift:22`.
- **L52.** Empty `timelinePath` arrays produce point-less path events, violating the documented ≥1-sample invariant. `GoogleTakeoutDecoder.swift:158`.

### Lifecycle
- **L53.** PHImageManager requests are uncancellable (request ID discarded; continuation ignores cancellation). `PhotoLibraryService.swift:138`.
- **L54.** `PHCachingImageManager` caching never engaged — every zoom/re-cluster refetches thumbnails cold. `PhotoLibraryService.swift:32`.
- **L55.** CLLocationManager delegate events bridged with independent unstructured Tasks — FIFO not guaranteed across event types. `LocationTracker.swift:697`.

### Error handling & platform (verified on Opus 4.8)
- **L56.** `loadDay` swallows all DB errors with `(try? …) ?? []` — a failed read renders as an empty day, indistinguishable from "no data" (unlike `refresh()`, which surfaces failures). `AppEnvironment.swift:410-445`.
- **L57.** An empty geocoder result is persisted as the resolved label `"Unknown location"` and excluded from every future retry (`fetchUnresolvedPlaceIDs` filters on `resolved_label IS NULL`). `GeocodingService.swift:212-214`.
- **L58.** Motion authorization never checked and `.waking` has no timeout — denied Motion & Fitness leaves probe GPS armed until a visit event fires (duplicate angle on M17, independently confirmed; actual code at `LocationTracker.swift:610-613`).
- **L59.** Limited photo library mode: `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` not set and no `presentLimitedLibraryPicker` UI — iOS periodically auto-presents the "Select More Photos" modal over the map. `Info.plist`.
- **L60.** First "Locate me" tap does nothing: the camera only centers if `lastKnown` is already non-nil, and nothing observes the fix that arrives afterward. `MapScreen.swift:117-121`.

### Test quality (verified on Opus 4.8)
- **L61.** `testRevertRestoresOriginalsAndRemovesAuditAndSnapshot` asserts the **opposite** of its name (`XCTAssertTrue(restored.isEmpty)`); revert actually deletes the snapshot without copying it back, relying on sibling path events. Rename + add a test of the real recovery path. `RefinementQueriesTests.swift:102`.
- **L62.** `testReturnsMarkersWithIncreasingDistanceFromStart` never asserts position, order, or spacing — all markers at one coordinate would pass. `PolylineDirectionTests.swift:61`.
- **L63.** `MotionAggregator.dominantMode` tie-break depends on Dictionary iteration order, and the tests deliberately accept either winner — nondeterminism codified. `MotionAggregatorTests.swift:51`, `MotionAggregator.swift:75`.
- **L64.** The key end-to-end import tests `XCTSkip` unless the developer's personal 16k-event Takeout file exists outside the repo — they vanish silently on CI/other machines and assert against uncontrolled data. `EndToEndImportTests.swift:10`, `GoogleTakeoutDecoderTests.swift:101`.

---

## Refuted findings (for transparency)

Seven claims were investigated and rejected by the adversarial verifiers — kept here so they aren't re-reported:

1. **"Background-relaunch fix dropped because tracker enables only after ensureOpen"** — refuted: `LocationTracker.init` synchronously reads the enabled flag and arms SLC/visits before any callback can land; the developer already fixed exactly this (the *Keychain* failure mode in H2 is the part that remains real).
2. **"Cancelled history-refine runner races onDisappear day-restore"** — refuted: `loadDay` has no suspension points on the MainActor; every interleaving restores the original day.
3. **"Tracking resume races the async DB open / skipped if DB fails"** — refuted: same synchronous-init reasoning; degraded no-persistence mode is documented intended behavior.
4. **"Orphan recovery writes Null Island (0,0) activities"** — refuted: the quoted code doesn't exist; empty orphans are deleted, and the doc comment explicitly describes (0,0) as the *old, fixed* behavior.
5. **"openDatabase() + public raw-SQL primitives let any feature run arbitrary SQL"** — refuted: zero raw-SQL call sites exist outside the Persistence package; the handle is the documented way to reach the typed query layer. (At most an API-hygiene nit.)
6. **"Orphan recovery writes (0,0) Null Island activities"** (errors-dimension variant) — refuted again by a second independent verifier: the quoted `writeActivity(startCoord: Coordinate(0,0), …)` call doesn't exist; fix-less orphans are deleted.
7. **"Location/visit events delivered before async ensureOpen() completes are dropped on background relaunch"** — refuted: `LocationTracker.init` arms the state machine synchronously from UserDefaults before any callback can land (the developer's comment narrates this exact scenario). The real residual failure in that flow is the Keychain one (H2).
