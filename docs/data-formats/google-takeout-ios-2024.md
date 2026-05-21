# Google Takeout — iOS Location History format (2024+)

The user's `location-history.json` is the **iOS Takeout format**, distinct from the older Android / web-Timeline format (`Records.json` + `Semantic Location History/<year>/<year>_<month>.json`).

Top-level shape:

```json
[
  { ...record 1... },
  { ...record 2... },
  ...
]
```

A flat array of records, each with exactly one of three discriminator keys: `activity`, `visit`, or `timelinePath`. All records carry an `endTime` and `startTime` (ISO 8601 with offset, e.g. `2023-08-23T07:52:01.117+02:00`).

## 1. `activity` — A→B movement

```json
{
  "startTime" : "2023-08-23T06:56:03.696+02:00",
  "endTime"   : "2023-08-23T07:52:01.117+02:00",
  "activity" : {
    "start" : "geo:47.060450,6.593421",
    "end"   : "geo:46.997669,6.943593",
    "distanceMeters" : "29132.000000",
    "topCandidate" : {
      "type" : "in passenger vehicle",
      "probability" : "0.000000"
    }
  }
}
```

- `start` / `end` use the `geo:lat,lon` URI scheme.
- All numeric fields are **strings**, including `distanceMeters` and `probability`. Decoders must handle that.
- `topCandidate.type` values observed: `walking`, `running`, `cycling`, `in passenger vehicle`, `in subway`, `in train`, `in bus`, `motorcycling`, `flying`, `still`, others.

## 2. `visit` — stayed at a place

```json
{
  "startTime" : "2023-08-23T07:52:01.117+02:00",
  "endTime"   : "2023-08-23T18:02:50.990+02:00",
  "visit" : {
    "hierarchyLevel" : "0",
    "probability"    : "0.930000",
    "topCandidate" : {
      "placeID"        : "ChIJo70GByMKjkcRNWiVPq3uXQY",
      "placeLocation"  : "geo:46.996510,6.942961",
      "semanticType"   : "Unknown",
      "probability"    : "0.793349"
    }
  }
}
```

- `placeID` is the Google Place ID. We store it as-is for the user's local benefit (linking same place over time). It is not exfiltrated.
- `semanticType` values observed: `Home`, `Work`, `Unknown`, `Search` (others likely).
- `hierarchyLevel` is `"0"` in all observed records; reserved field for future use.

## 3. `timelinePath` — raw GPS breadcrumbs

```json
{
  "startTime" : "...",
  "endTime"   : "...",
  "timelinePath" : [
    { "point" : "geo:46.997174,6.944278", "durationMinutesOffsetFromStartTime" : "0" },
    { "point" : "geo:46.998039,6.941652", "durationMinutesOffsetFromStartTime" : "7" }
  ]
}
```

- Variable number of points per segment.
- `durationMinutesOffsetFromStartTime` is the offset (in whole minutes, string-encoded) from the segment's `startTime`.

## Decoding notes

- Numbers as strings: decode `Double` / `Int` via custom `Codable` that calls `Double($0)` on the string.
- `geo:lat,lon` parser: split on `:` and `,`, then `Double` each half.
- Timezone offsets in timestamps **must be preserved** — see the `(epoch_utc, tz_offset_minutes)` storage scheme in `architecture.md`.
- A single record may be malformed in the wild; the importer should skip and report rather than abort.

## Sample size in this repo

`sample-data/google-takeout/location-history.json` is the user's real export. Synthetic minimal version: [fixtures/google-takeout-minimal.json](../../fixtures/google-takeout-minimal.json) — one record of each kind, coordinates near `(0, 0)`.
