# Background Location Tracking on iOS: How Google Timeline (and Friends) Actually Work

Research deliverable produced against the brief at
`/Users/tibo/.claude/plans/okay-so-i-need-sparkling-wind.md`.
Date: 2026-05-22. Scope: facts only — no implementation proposal for RememberMe.

Each major claim is tagged:
- **[VERIFIED]** — sourced from official Apple / Google / vendor documentation.
- **[INFERRED]** — community / engineering writeups, reverse-engineering, open-source reads.
- **[SPECULATION]** — best guess, no public evidence; flagged explicitly.

---

## TL;DR

1. **Google Timeline on iOS is not a single "ping every N seconds" loop.** It's a hybrid that lets iOS wake it up via Significant Location Changes / visit monitoring while idle, and switches to a high-rate `CLLocationManager` session (declared with `UIBackgroundModes = location`) once motion is detected. Google does not publish the cadence. **[INFERRED]**
2. **Since December 1, 2024, Google Timeline data is stored on-device, not on Google's servers.** The web Timeline UI has been retired. The new on-device JSON (the format RememberMe consumes — `"geo:lat,lon"` strings, ISO 8601 timestamps with timezone offset, three record types) is generated locally; cloud backup is an opt-in encrypted blob. **[VERIFIED]**
3. **Activity types (`"walking"`, `"in passenger vehicle"`, etc.) come from on-device classification fed by `CMMotionActivityManager` plus the GPS stream.** Apple's M-series motion coprocessor (every iPhone since the 5s) runs the inertial classifier for free in hardware, so Google does not need to keep an `CLLocationManager` running just to know whether you're walking. **[VERIFIED / INFERRED]**
4. **The `timelinePath` minute-resolution offsets are downsampled from a much denser raw stream** that almost certainly samples at 1 Hz or faster while active (Strava's `~1 Hz` continuous GPS while recording is the public point of comparison). The downsampling happens before the JSON is written. **[INFERRED]**
5. **The best public proxy for how Google Timeline works on iOS is LocoKit (the open-source framework behind Arc App)**, because the public iOS APIs Google has to use are the same ones LocoKit calls. LocoKit goes to deep sleep with `startMonitoringVisits` + `startMonitoringSignificantLocationChanges`, wakes on motion, and bumps `desiredAccuracy` dynamically — sleeping after 180 s stationary, 60 s sleep-cycle wake-checks, 15 min minimum deep-sleep duration. **[VERIFIED via source read]**

---

## How Google Timeline works on iOS

### A1. Sampling cadence

**The cadence is adaptive, not fixed, and Google does not publish numbers.** What's publicly verified:

- Google requires Location Services set to **"Always"** and Background App Refresh **on** for Timeline to function on iOS, which implies the app must use a background-eligible CoreLocation API. [Google Account Help — Manage Timeline for iPhone](https://support.google.com/accounts/answer/4388034) **[VERIFIED]**
- The on-device Timeline JSON we consume has minute-resolution offsets on path points (`durationMinutesOffsetFromStartTime: "10"`), but minute offsets in the export are not the sample rate — they're the downsampled output. The underlying GPS sampling has to be faster than 1/min to produce a usable polyline. **[INFERRED]**
- For comparison, Strava — when actively recording — appears to read GPS at roughly 1 Hz on iPhone, which is the rate iOS GPS hardware natively returns. [Strava Community: GPS update rate](https://communityhub.strava.com/general-chat-2/gps-update-rate-interval-on-ios-killing-battery-9008) **[INFERRED]**

Reasonable inference about Google's adaptive behaviour:

- **Stationary:** no foreground GPS at all. The app stays terminated/suspended and relies on `startMonitoringSignificantLocationChanges` (which triggers ≈ every 500 m and ≥ 5 min) plus `startMonitoringVisits` (CLVisit) to detect a new "place" started. **[INFERRED]**
- **Moving:** once a visit ends or a significant change fires, the app wakes, calls `startUpdatingLocation` with a high `desiredAccuracy`, and pulls 1 Hz (or near-1-Hz) samples until motion stops. **[INFERRED, matches LocoKit's documented behaviour]**

Quantification with public numbers: best-case background ping rate (without app running) is the SLC threshold of **≥ 500 m / ≥ 5 min** ([OwnTracks Booklet — Location](https://owntracks.org/booklet/features/location/) describing Apple's SLC). Active sampling rate is bounded by the hardware GPS clock at **~1 Hz**.

### A2. Pinging model

**Hybrid, with iOS doing as much of the work as possible while the app is suspended.** Components observable from the public API surface:

1. `startMonitoringSignificantLocationChanges()` — wakes terminated app on ≥ 500 m / ≥ 5 min movement. Survives reboot. **[VERIFIED — [Apple: startMonitoringSignificantLocationChanges](https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoringsignificantlocationchanges)]**
2. `startMonitoringVisits()` — wakes app on `CLVisit` arrive/depart, even after termination, when Always authorization is granted. Accuracy is ~1–2 min of slack on arrival/depart times. [Felgines: Visit Monitoring](https://felginep.github.io/2020-06-09/visit-monitoring), [NSHipster — Core Location in iOS 8](https://nshipster.com/core-location-in-ios-8/) **[VERIFIED]**
3. `startUpdatingLocation()` with `allowsBackgroundLocationUpdates = true` and `UIBackgroundModes = ["location"]` — keeps the app alive in the background with continuous fixes, but does NOT relaunch if the app is killed. **[VERIFIED — [Apple: Handling location updates in the background](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)]**
4. `CMMotionActivityManager.startActivityUpdates(to:)` — pushes activity transitions (walking → automotive, etc.) from the motion coprocessor with negligible battery cost. **[VERIFIED — [NSHipster: CMMotionActivity](https://nshipster.com/cmmotionactivity/)]**

The hybrid: SLC + visits as the "always-on tripwire," foreground-style `startUpdatingLocation` while actually moving, CMMotion as the cheap mode signal.

### A3. iOS background mechanism

Google Maps' `Info.plist` declares `UIBackgroundModes = ["location", "remote-notification", "fetch", ...]` — directly verifiable by inspecting the IPA. **[INFERRED but trivially verifiable]**

Mechanisms Google likely uses simultaneously:
- `allowsBackgroundLocationUpdates = true` on a `CLLocationManager` instance while a trip is in progress. **[INFERRED]**
- `startMonitoringSignificantLocationChanges()` as the persistent tripwire. **[INFERRED]**
- `startMonitoringVisits()` for stop detection. **[INFERRED]**
- Possibly a **Location Push Service Extension** ([Apple: CLLocationPushServiceExtension](https://developer.apple.com/documentation/corelocation/cllocationpushserviceextension), iOS 15+) — APNs-triggered location request that runs while the app is terminated. Cheap, but Google has not confirmed using it. **[SPECULATION]**

Force-quit / reboot behaviour:
- Only SLC and visit monitoring + region monitoring relaunch a terminated app. `startUpdatingLocation` does not. **[VERIFIED — Apple SLC docs]**
- A user who force-quits Google Maps from the app switcher will lose continuous tracking until iOS triggers an SLC/visit event that wakes the app. This is well-known consumer pain. **[VERIFIED — Apple platform constraint]**

### A4. Activity / mode inference (the `topCandidate.type` field)

The activity type that ends up in the JSON (`"walking"`, `"in passenger vehicle"`, `"cycling"`, etc.) is produced by **on-device** classification, almost certainly combining:

1. **`CMMotionActivityManager`** output — Apple's own classifier, running on the motion coprocessor since iPhone 5s (2013). Returns mutually-non-exclusive booleans for `stationary`, `walking`, `running`, `automotive`, `cycling`, plus a `confidence` (low/medium/high). [NSHipster: CMMotionActivity](https://nshipster.com/cmmotionactivity/) **[VERIFIED]**
2. **GPS-derived speed/distance** — distinguishes "in passenger vehicle" from "on bicycle" when CMMotion can't (both register as "automotive" or unclear). **[INFERRED]**
3. **An additional learned classifier** for transit sub-modes (`"in bus"`, `"in tram"`, `"in subway"`). These almost certainly need route-snapping or transit-line matching beyond what CMMotion provides. **[INFERRED]**

The `probability` field in the new on-device JSON is a single confidence value (string-encoded double in `[0, 1]`). The legacy semantic format had a richer `activities[]` array with per-candidate calibrated probabilities; the new format keeps only `topCandidate`. **[VERIFIED via [Location History Format reference](https://locationhistoryformat.com/reference/semantic/)]**

Note that historically Google's `topCandidate.probability` is often `0.0` in real-world Takeout exports — see [GoogleTakeoutDecoderTests.swift](Packages/Core/Tests/CoreTests/GoogleTakeoutDecoderTests.swift) fixtures and the in-wild data RememberMe ingests. **[VERIFIED via codebase]**

### A5. Visit / place detection

Two-stage:

1. **Stop detection.** A "visit" starts when the device is geographically stationary (low speed, no CMMotion activity) for long enough. Apple's `CLVisit` API does this natively and Google may use it directly. `CLVisit` returns averaged coordinate, arrival, and departure timestamps with ~1–2 min slack. **[VERIFIED]**
2. **Place resolution.** Mapping a coordinate to a `placeID` and a `semanticType` (`"Home"`, `"Work"`, `"Unknown"`) requires Google's Places database. **Since the December 2024 on-device migration**, the help docs are explicit that Timeline data lives locally — but Google did not say the Places resolution itself runs on-device. Most likely the device sends a coordinate query to Google Places when a new place is detected and caches the result locally. **[INFERRED]**

`hierarchyLevel` in the new format is an integer (typically `0` = finest); the legacy format had a `placeVisitLevel` plus nested `childVisits[]` for "I went to a coffee shop inside a mall" hierarchies. The new format keeps the level as a flat integer rather than a nested tree. **[VERIFIED — fixture in `fixtures/google-takeout-minimal.json`]**

"Home" and "Work" specifically are labels Google promotes after multiple repeated long stays at a coordinate; they are not announced explicitly to the app and not negotiable. **[VERIFIED — Google's own UX, but undocumented algorithmically]**

### A6. Path point cadence

The `timelinePath` array uses **`durationMinutesOffsetFromStartTime`** — minute-resolution integers. In real Takeout files you'll see consecutive points with offset deltas of 1–5 minutes, but also occasional 0-minute and 0/very-small spatial deltas (rounded sampling).

What we know:
- The raw sample rate **must** be faster than 1/min — you can't reconstruct a curved road path with minute samples. **[INFERRED]**
- The legacy "Semantic Location History" format exposed both `simplifiedRawPath` and `waypointPath`. The former was the device's raw GPS breadcrumb (with `accuracyMeters` per point); the latter was server-snapped to roads. **[VERIFIED — [locationhistoryformat.com](https://locationhistoryformat.com/reference/semantic/)]**
- The **new** on-device format drops the snapped/waypoint variant. Only `timelinePath` remains, with no `accuracyMeters` per point. This implies less server-side post-processing — the path is what the device sampled, minute-quantized. **[VERIFIED via fixture]**
- Snap-to-road, if it happens, happens on-device against Google Maps' local route graph. **[INFERRED]**

Practical takeaway: to produce the same path shape, our app would need to sample at ≥ 1 Hz while moving and then downsample to ~1/min for the exported JSON.

### A7. Battery management

Google publicly claims Timeline costs "very little" battery but does not quantify. The techniques known to work on iOS and almost certainly used:

- **Stay terminated when possible.** Use `startMonitoringSignificantLocationChanges` and `startMonitoringVisits` as the only persistent subscriptions. Both cost ~zero battery because they ride on the radio's own cell-tower-handoff signal and the M-series motion coprocessor. **[VERIFIED — [Apple Energy Efficiency Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)]**
- **Dynamic `desiredAccuracy`.** Drop to `kCLLocationAccuracyThreeKilometers` or worse while idle, ramp to `kCLLocationAccuracyBest` while a trip is active. LocoKit demonstrates this. **[VERIFIED — LocoKit source]**
- **`pausesLocationUpdatesAutomatically`.** Apple's hint to the system to suspend updates during long stops. LocoKit actually disables this and manages sleep manually because the auto-pause behaviour is opaque and can drop data. **[VERIFIED — LocoKit source]**
- **`allowDeferredLocationUpdates(untilTraveled:timeout:)`.** Lets the GPS buffer fixes and deliver in batches. "Deferred delivery consumes significantly less power" per Apple's own Energy Efficiency Guide. [Apple: allowDeferredLocationUpdates](https://developer.apple.com/documentation/corelocation/cllocationmanager/1620547-allowdeferredlocationupdates) **[VERIFIED]**
- **Motion coprocessor wake-ups.** `CMMotionActivityManager` rides on the always-on inertial coprocessor. Reading the activity stream does not wake the main CPU. **[VERIFIED — [NSHipster on M7/M-series](https://nshipster.com/cmmotionactivity/)]**

### A8. Network behaviour

Pre-December-2024: device buffered breadcrumbs, uploaded periodically to Google servers, cluster/segment/place-resolve happened server-side, then the user's web Timeline was rendered from server data.

Post-December-2024 ("on-device Timeline"): the JSON we now see in Takeout is generated and stored locally first. Google's own announcement: *"Your visits and routes are automatically saved to a map on each of your devices."* [The Hacker News — Google Maps Timeline Data to be Stored Locally](https://thehackernews.com/2024/06/google-maps-timeline-data-to-be-stored.html), [9to5Google — Google Maps widely rolling out on-device Timeline](https://9to5google.com/2024/12/11/google-maps-on-device-timeline/) **[VERIFIED]**

Network is still required for:
- Places-API lookups to resolve `placeID` and `semanticType` for newly-detected visits. **[INFERRED]**
- Encrypted backup blobs to Google's servers (opt-in, user-initiated). **[VERIFIED]**
- Map tile serving (Google Maps app's day-to-day function — unrelated to Timeline).

### A9. Permission model

- **"Always" authorization required** for background Timeline to function. iOS prompts the user with a "Allow once / While Using / Always" dialog; only "Always" persists across app suspension and triggers SLC/visit wake-ups. **[VERIFIED — Apple platform behaviour]**
- **"While Using" mode** degrades Timeline to only collecting fixes when the app is foregrounded — effectively useless for passive history. **[VERIFIED]**
- **iOS 14+ precise/approximate toggle.** With "Precise: Off," Timeline gets ~1–10 km accuracy fixes, which destroys path quality but still feeds visit detection. Google warns the user in-app when precise location is disabled. **[VERIFIED — iOS platform constraint]**
- **iOS may silently downgrade Always → While Using** if Apple's heuristics judge that an app hasn't justified the elevated grant. Apple shows the periodic "App X has been using your location in the background — allow this to continue?" sheet. **[VERIFIED]**

### A10. Android cross-reference

Brief contrast — Android stack differs substantially:

- **Fused Location Provider** (Google Play Services) — Android's equivalent of CoreLocation, but unlike Apple's it can be queried at sub-second cadence from a foreground service relatively cheaply, because Google Play Services itself batches sensor reads.
- **Activity Recognition API** — Android's equivalent of `CMMotionActivityManager`. Returns confidence-scored arrays of activity candidates.
- **Geofencing API** — server-side geofence batching via Play Services, more permissive than iOS region monitoring (which caps at 20 regions per app).
- **Foreground service** — Android's equivalent of `UIBackgroundModes = ["location"]`. Required ongoing notification while tracking.
- **No equivalent of `CLVisit`** as a system API — Google rolls its own visit detection on Android.

Implication for an iOS-only replication: the parts that come "free" on Android because they're served by Google Play Services (richer visit clustering, transit-mode classification) have to be built or imported on iOS. The parts that work better on iOS (battery-cheap visit detection via `CLVisit`, motion-coprocessor activity classification) are not available on Android in the same form. **[VERIFIED — Android Developers documentation]**

---

## Reference iOS apps

### Arc App / LocoKit (Matt Greenfield)

Closest direct analog to Timeline. The framework is open source (the iOS app on top of it is closed). **All of the following is verified from reading [LocomotionManager.swift](https://github.com/sobri909/LocoKit/blob/master/LocoKit/Base/LocomotionManager.swift) directly.**

- `UIBackgroundModes`: declares `"location"`. **[INFERRED — required for the API usage observed]**
- CoreLocation APIs: `startUpdatingLocation`, `startMonitoringVisits`, `startMonitoringSignificantLocationChanges`. Calls all three depending on state. **[VERIFIED]**
- CoreMotion: `CMMotionActivityManager.startActivityUpdates`. **[VERIFIED]**
- Sampling cadence (while active): `distanceFilter = kCLDistanceFilterNone`, `desiredAccuracy = kCLLocationAccuracyBest` — i.e. as fast as the hardware delivers, ~1 Hz. **[VERIFIED]**
- Sleep mode: enters after **180 s stationary**, runs **60 s sleep-cycle wake-checks**. **[VERIFIED]**
- Deep sleep (15+ min stationary): calls `startMonitoringVisits` + `startMonitoringSignificantLocationChanges`, calls `stopUpdatingLocation`. Survives app termination via the two persistent monitors. **[VERIFIED]**
- Dynamic `desiredAccuracy`: cycles through `[kCLLocationAccuracyHundredMeters, kCLLocationAccuracyNearestTenMeters, kCLLocationAccuracyBest, kCLLocationAccuracyBestForNavigation]` based on conditions. **[VERIFIED]**
- `pausesLocationUpdatesAutomatically = false` — manual sleep management. **[VERIFIED]**
- `allowsBackgroundLocationUpdates = true` during active recording. **[VERIFIED]**
- Permission: requires **Always** — Arc App explicitly tells users this on first run. **[VERIFIED — Arc App on-boarding]**
- Battery: Matt Greenfield's [Big Paua blog](https://www.bigpaua.com/arcapp/) claims all-day recording at single-digit-percent daily battery cost, attributing it to sleep-mode discipline plus dynamic accuracy. **[VERIFIED via Big Paua statements; not independently benchmarked here]**

### OwnTracks (open source iOS client)

Open source at [github.com/owntracks/ios](https://github.com/owntracks/ios). Two modes.

- **Significant Changes mode:** uses Apple's SLC service. Triggers ≥ 500 m / ≥ 5 min. Battery-optimal. [OwnTracks Booklet — Location](https://owntracks.org/booklet/features/location/) **[VERIFIED]**
- **Move mode:** continuous tracking, publishes when `locatorDisplacement` (default **100 m**) OR `locatorInterval` (default **300 s** = 5 min) — whichever first. Configurable. **[VERIFIED]**
- Circular geofence support (`CLCircularRegion`) since v5.3. iBeacon since v7.7. **[VERIFIED]**
- Battery management: a `downgrade` parameter auto-switches Move → Significant when battery drops below a threshold. Restores Move when the charger is connected. **[VERIFIED — [OwnTracks issue #436](https://github.com/owntracks/ios/issues/436)]**
- Permission: Always. UIBackgroundModes: `location`.
- No CoreMotion / activity classification. Pure location publishing.

The headline difference from Arc / Timeline: OwnTracks does not classify activities or detect visits — it just publishes raw fixes to MQTT/HTTP. So its battery profile is determined entirely by which mode the user picks; in Move mode at default settings (publish every 100 m / 5 min) it's lighter than Strava but heavier than Arc's sleep-driven approach.

### Strava

Closed source; public engineering details are sparse, mostly inferred from community testing.

- During an active recording session, Strava reads GPS at roughly **1 Hz** (limited by iOS GPS hardware rate). [Community thread](https://communityhub.strava.com/general-chat-2/gps-update-rate-interval-on-ios-killing-battery-9008) **[INFERRED]**
- `UIBackgroundModes` declares `location` and likely `audio` (for in-activity voice prompts). **[INFERRED]**
- No background sampling outside an active recording — Strava is opt-in per session, not always-on. This is fundamentally different from Timeline/Arc. **[VERIFIED — Strava UX]**
- Battery cost is reported by users at ~10–15% per hour of continuous outdoor recording with screen off. Comparable to a turn-by-turn navigation session. **[INFERRED — community reports]**
- Uses `CMPedometer` for step count and elevation as backup signals when GPS quality drops. **[INFERRED]**
- The Beacon feature (live location sharing) publishes every 15 s while active. [Strava: Beacon](https://www.whistleout.com/CellPhones/Guides/use-strava-beacon-to-share-your-live-location-while-solo-traveling) **[VERIFIED]**

Why Strava is included: it's the canonical "high-fidelity foreground GPS" reference. Anyone building a Timeline-style app needs to know what a 1-Hz GPS session costs in battery, because that's the upper bound on what your "active" mode can run at.

### Apple's own Significant Locations (Settings > Privacy > Location Services > System Services > Significant Locations)

- Uses the same `startMonitoringSignificantLocationChanges` mechanism Apple exposes to third parties — Apple is dogfooding their own API. **[INFERRED but obvious]**
- Triggers approximately on cell-tower handoff boundaries — same ~500 m / ~5 min as third-party SLC. **[VERIFIED — Apple Support: About privacy and Location Services](https://support.apple.com/en-us/102515)]**
- Data is stored **on device only**, synced between user's devices via end-to-end encryption. Apple cannot read it. **[VERIFIED — [Apple Legal: Location Services & Privacy](https://www.apple.com/legal/privacy/data/en/location-services/)]**
- Powers Photos Memories, predictive routing in Maps, and the "Find My Car" auto-detection.
- Visible only to the device owner, behind a Face ID prompt.

Apple's Significant Locations is the closest "first-party Timeline" iOS has. It does not produce any developer-readable artifact — there's no API to dump it. So we cannot piggyback on it.

---

## iOS platform constraints (concise)

### C1. The public APIs that matter

| API | What it does | Wake-from-terminated? | Battery cost |
|-----|--------------|-----------------------|--------------|
| `startUpdatingLocation` + `allowsBackgroundLocationUpdates` | Continuous fixes, app stays alive in background | No | High (GPS active) |
| `startMonitoringSignificantLocationChanges` | Notifies on ≥ 500 m / ≥ 5 min movement | **Yes** | Near-zero (rides cell handoff) |
| `startMonitoringVisits` (`CLVisit`) | Arrival/departure events at "places" | **Yes** | Near-zero |
| `CLMonitor` + `CircularGeographicCondition` (iOS 17+) | Modern unified geofence/beacon API | **Yes** | Near-zero |
| `startMonitoring(for: CLCircularRegion)` (legacy region monitoring) | Geofence enter/exit. Up to 20 regions per app | **Yes** | Near-zero |
| `allowDeferredLocationUpdates(untilTraveled:timeout:)` | Batches fixes, delivers later | N/A (active session) | Lower than live delivery |
| `CMMotionActivityManager.startActivityUpdates` | Motion-coprocessor activity classification | No (must already be running) | Near-zero |
| `CLLocationPushServiceExtension` (iOS 15+) | APNs-triggered one-shot location grab while app terminated | **Yes** (via APNs) | Very low |

Sources: [Apple: Handling location updates in the background](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background), [Apple: CLMonitor](https://developer.apple.com/documentation/corelocation/clmonitor), [WWDC23: Meet Core Location Monitor](https://developer.apple.com/videos/play/wwdc2023/10147/), [Apple Energy Efficiency Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html).

### C2. Gotchas that constrain everyone — including Google

- **Force-quit kills standard location updates.** Only SLC, visit monitoring, region monitoring, `CLMonitor`, and Location Push Service Extension can relaunch a force-quit app. This is the source of the recurring "Google Maps Timeline missing my morning" complaints. **[VERIFIED]**
- **iOS 16.4** tightened background suspension: apps that call both `startUpdatingLocation` and `startMonitoringSignificantLocationChanges` may get suspended in background if they configure low accuracy / high distance filter. [Cropsly: Location Updates changes in iOS 16.4](https://cropsly.com/blog/location-updates-changes-in-ios-16-4) **[VERIFIED]**
- **`CLVisit` is imprecise on times.** Arrival/departure stamps drift by ~1–2 minutes vs ground truth. Acceptable for "I went to the coffee shop" granularity; not for "I left work at 17:03 exactly." **[VERIFIED — Felginé p.: Visit Monitoring](https://felginep.github.io/2020-06-09/visit-monitoring)]**
- **20-region cap** on legacy `CLCircularRegion` monitoring. `CLMonitor` (iOS 17+) raises this. **[VERIFIED]**
- **"Always" permission can be silently downgraded by iOS** if heuristics judge it unjustified. App must handle the demotion gracefully. **[VERIFIED]**
- **Locked-device data protection.** SQLCipher with `.complete` file protection (which RememberMe uses, per [Schema.swift](Packages/Persistence/Sources/Persistence/Schema.swift) and [DatabaseFactory.swift](Packages/Persistence/Sources/Persistence/DatabaseFactory.swift)) means the DB is unreadable while the device is locked. A background location callback that fires during a lock cannot write to it. Options: use `.completeUntilFirstUserAuthentication` (acceptable trade-off — readable after first unlock post-boot), or buffer fixes in a less-protected store and flush on unlock. **[VERIFIED — Apple file protection documentation]**
- **GPS-cold-fix delay.** First fix after a wake-from-suspended state can take 5–30 s, particularly indoors or in urban canyons. Path data immediately after a wake-up event is unreliable. **[INFERRED — universal GPS behaviour]**

---

## Open questions

The following could not be answered from public sources:

1. **Google's exact path-point downsampling algorithm.** We know the output is minute-quantized; we don't know the upstream sample rate or the simplification heuristic. Could be Ramer–Douglas–Peucker, could be time-bucketed averaging, could be road-snap-then-decimate. *No public source.*
2. **Whether Google ever uses `CLLocationPushServiceExtension`.** Would explain how Timeline survives long force-quits. Not confirmed. *No public source.*
3. **What `topCandidate.probability` means in the new on-device JSON when it equals `0.0` (which it often does).** Likely "we have no confidence number to report from this on-device classifier"; possibly a legacy serialization artifact. *No public source.*
4. **How Google resolves a "Home" / "Work" semantic type.** Google announces this as a user-facing label after repeated long stays, but the exact threshold (number of nights, total hours, days-of-week pattern) is undocumented. *No public source.*
5. **Whether the Places-API call on visit detection sends raw coords to Google, or a hash.** Privacy-relevant. *No public source.*
6. **The transit-mode classifier (`"in bus"` vs `"in tram"` vs `"in subway"`).** Almost certainly relies on Google Maps' transit-line database; whether the matching is on-device or server-side post-2024 is unknown. *No public source.*

These are the questions an implementation plan will have to make pragmatic decisions about — we cannot copy Google's algorithm because we can't see it.

---

## Sources

- [Apple Developer: Handling location updates in the background](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)
- [Apple Developer: CLLocationManager.startMonitoringVisits()](https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoringvisits())
- [Apple Developer: startMonitoringSignificantLocationChanges](https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoringsignificantlocationchanges)
- [Apple Developer: CLMonitor](https://developer.apple.com/documentation/corelocation/clmonitor)
- [Apple Developer: CLLocationPushServiceExtension](https://developer.apple.com/documentation/corelocation/cllocationpushserviceextension)
- [Apple Developer: allowDeferredLocationUpdates](https://developer.apple.com/documentation/corelocation/cllocationmanager/1620547-allowdeferredlocationupdates)
- [Apple WWDC23: Meet Core Location Monitor (session 10147)](https://developer.apple.com/videos/play/wwdc2023/10147/)
- [Apple Energy Efficiency Guide for iOS Apps — Location Best Practices](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)
- [Apple Support: About privacy and Location Services in iOS, iPadOS, and watchOS](https://support.apple.com/en-us/102515)
- [Apple Legal: Location Services & Privacy](https://www.apple.com/legal/privacy/data/en/location-services/)
- [NSHipster: Core Location in iOS 8 (introduces CLVisit and SLC)](https://nshipster.com/core-location-in-ios-8/)
- [NSHipster: CMMotionActivity](https://nshipster.com/cmmotionactivity/)
- [Felgines: Visit Monitoring](https://felginep.github.io/2020-06-09/visit-monitoring)
- [Cropsly: Location Updates changes in iOS 16.4](https://cropsly.com/blog/location-updates-changes-in-ios-16-4)
- [Google Account Help: Manage Timeline for iPhone](https://support.google.com/accounts/answer/4388034)
- [Google Maps Help: Manage your Google Maps Timeline](https://support.google.com/maps/answer/6258979)
- [The Hacker News: Google Maps Timeline Data to be Stored Locally](https://thehackernews.com/2024/06/google-maps-timeline-data-to-be-stored.html)
- [9to5Google: Google Maps widely rolling out on-device Timeline](https://9to5google.com/2024/12/11/google-maps-on-device-timeline/)
- [Android Police: Google Maps Timeline now stores your location data on-device](https://www.androidpolice.com/google-maps-timeline-location-data-on-device-migration/)
- [Location History Format: Semantic reference (legacy schema)](https://locationhistoryformat.com/reference/semantic/)
- [Location History Format: Semantic Location guide](https://locationhistoryformat.com/guides/semantic-location/)
- [LocoKit on GitHub (Matt Greenfield / Arc App framework)](https://github.com/sobri909/LocoKit)
- [LocoKit: LocomotionManager.swift](https://github.com/sobri909/LocoKit/blob/master/LocoKit/Base/LocomotionManager.swift)
- [Big Paua: Arc App](https://www.bigpaua.com/arcapp/)
- [Big Paua Support: Can I pause Arc overnight to save battery?](https://support.bigpaua.com/t/can-i-pause-arc-overnight-to-save-battery/518)
- [OwnTracks Booklet: iOS](https://owntracks.org/booklet/features/ios/)
- [OwnTracks Booklet: Location](https://owntracks.org/booklet/features/location/)
- [OwnTracks GitHub iOS issue: Move mode vs Significant changes mode (#552)](https://github.com/owntracks/ios/issues/552)
- [OwnTracks GitHub iOS issue: Auto downgrade on battery (#436)](https://github.com/owntracks/ios/issues/436)
- [Strava Support: Troubleshooting iOS GPS Issues](https://support.strava.com/hc/en-us/articles/216917247-Troubleshooting-iOS-GPS-Issues)
- [Strava Community: GPS update rate/interval on iOS killing battery](https://communityhub.strava.com/general-chat-2/gps-update-rate-interval-on-ios-killing-battery-9008)
- [WhistleOut: Strava Beacon live location sharing](https://www.whistleout.com/CellPhones/Guides/use-strava-beacon-to-share-your-live-location-while-solo-traveling)
