import CryptoKit
import Foundation

/// Decodes Google Takeout iOS-format `location-history.json` into `[Event]`.
///
/// The Takeout file is a flat array of records, each with `startTime` / `endTime` plus
/// exactly one of `activity` / `visit` / `timelinePath`. All numeric fields arrive as
/// strings — this decoder converts them.
public struct GoogleTakeoutDecoder {
    public struct Result: Sendable {
        public let events: [Event]
        /// Records the decoder skipped because they were malformed in some recoverable way
        /// (unknown discriminator, unparseable `geo:` URI, unparseable timestamp, etc.).
        public let skipped: [SkipReason]

        public init(events: [Event], skipped: [SkipReason]) {
            self.events = events
            self.skipped = skipped
        }
    }

    public struct SkipReason: Sendable, CustomStringConvertible {
        public let recordIndex: Int
        public let reason: String

        public init(recordIndex: Int, reason: String) {
            self.recordIndex = recordIndex
            self.reason = reason
        }

        public var description: String {
            "record \(recordIndex): \(reason)"
        }
    }

    public enum DecodeError: Error, CustomStringConvertible, LocalizedError {
        case malformedJSON(underlying: Error)
        /// The top-level JSON isn't the iOS-device `[record, …]` array — most often an
        /// Android/web Takeout export (`{"semanticSegments": …}` / `{"timelineObjects": …}`).
        case unsupportedFormat(detail: String)

        public var description: String {
            switch self {
            case let .malformedJSON(underlying): "malformed Takeout JSON: \(underlying)"
            case let .unsupportedFormat(detail): detail
            }
        }

        public var errorDescription: String? { description }
    }

    public init() {}

    /// Internal result-like enum, used because `Swift.Result` requires `Failure: Error`
    /// and our failure case is just a human-readable string we attach to a skip report.
    private enum ConversionOutcome<Value> {
        case success(Value)
        case failure(String)
    }

    /// One top-level record decoded leniently: if the element doesn't match the iOS Takeout
    /// schema, the decoding error is captured here instead of aborting the whole file (M29).
    private struct LenientRecord: Decodable {
        let record: Wire.Record?
        let decodeError: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            do {
                record = try container.decode(Wire.Record.self)
                decodeError = nil
            } catch {
                record = nil
                decodeError = String(describing: error)
            }
        }
    }

    public func decode(_ data: Data) throws -> Result {
        let records = try decodeLenientRecords(data)

        var events: [Event] = []
        events.reserveCapacity(records.count)
        var skipped: [SkipReason] = []

        for (index, lenient) in records.enumerated() {
            append(lenient, at: index, into: &events, skipped: &skipped)
        }

        return Result(events: events, skipped: skipped)
    }

    /// Streaming variant: scans depth-1 record boundaries in the raw bytes and converts each
    /// record slice individually, delivering converted events in batches via `onBatch` so the
    /// caller can write incrementally instead of holding the whole file in memory (M28).
    /// Skips are reported the same way as `decode`. `onBatch` is called with a non-empty slice
    /// of events at most every `batchSize` events (and once more at the end if any remain).
    public func decodeStreaming(
        _ data: Data,
        batchSize: Int = 1000,
        onBatch: ([Event]) throws -> Void
    ) throws -> [SkipReason] {
        guard let slices = RecordScanner.recordSlices(in: data) else {
            try assertSupportedTopLevel(data)   // throws a specific error for known shapes
            throw DecodeError.unsupportedFormat(
                detail: "expected the iOS-device Takeout format: a top-level JSON array of records"
            )
        }

        var skipped: [SkipReason] = []
        var batch: [Event] = []
        batch.reserveCapacity(batchSize)
        let decoder = JSONDecoder()

        for (index, slice) in slices.enumerated() {
            let lenient: LenientRecord
            do {
                lenient = try decoder.decode(LenientRecord.self, from: slice)
            } catch {
                // A slice that isn't even a JSON object — treat as a per-record schema skip.
                skipped.append(SkipReason(recordIndex: index, reason: "unparseable record: \(error)"))
                continue
            }
            var produced: [Event] = []
            append(lenient, at: index, into: &produced, skipped: &skipped)
            batch.append(contentsOf: produced)
            if batch.count >= batchSize {
                try onBatch(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try onBatch(batch)
        }
        return skipped
    }

    // MARK: - Top-level decoding

    private func decodeLenientRecords(_ data: Data) throws -> [LenientRecord] {
        do {
            return try JSONDecoder().decode([LenientRecord].self, from: data)
        } catch {
            // Not a record array. Name the unsupported shape if we recognise it; otherwise
            // surface the raw JSON error.
            try assertSupportedTopLevel(data)
            throw DecodeError.malformedJSON(underlying: error)
        }
    }

    /// Throws a specific `unsupportedFormat` error when the top level is a recognised but
    /// unsupported Takeout shape (Android/web exports), so the user sees an actionable message
    /// instead of an opaque JSON error (L46).
    private func assertSupportedTopLevel(_ data: Data) throws {
        guard let top = try? JSONSerialization.jsonObject(with: data),
              let object = top as? [String: Any]
        else { return }
        let knownKeys = ["semanticSegments", "timelineObjects", "rawSignals", "userLocationProfile"]
        if let matched = knownKeys.first(where: { object[$0] != nil }) {
            throw DecodeError.unsupportedFormat(
                detail: "this looks like an Android or web Google Takeout export "
                    + "(top-level key \"\(matched)\"). RememberMe only supports the iOS-device "
                    + "export: a top-level JSON array of timeline records."
            )
        }
    }

    // MARK: - Per-record conversion

    private func append(
        _ lenient: LenientRecord,
        at index: Int,
        into events: inout [Event],
        skipped: inout [SkipReason]
    ) {
        if let reason = lenient.decodeError {
            skipped.append(SkipReason(recordIndex: index, reason: "schema mismatch: \(reason)"))
            return
        }
        guard let record = lenient.record else {
            skipped.append(SkipReason(recordIndex: index, reason: "empty record"))
            return
        }
        switch convert(record: record) {
        case let .success(event): events.append(event)
        case let .failure(reason): skipped.append(SkipReason(recordIndex: index, reason: reason))
        }
    }

    private func convert(record: Wire.Record) -> ConversionOutcome<Event> {
        guard let start = TimestampedLocal.parse(iso8601: record.startTime) else {
            return .failure("unparseable startTime '\(record.startTime)'")
        }
        guard let end = TimestampedLocal.parse(iso8601: record.endTime) else {
            return .failure("unparseable endTime '\(record.endTime)'")
        }

        // Exactly one of the three payload keys must be set.
        let payloadCount =
            (record.activity != nil ? 1 : 0)
                + (record.visit != nil ? 1 : 0)
                + (record.timelinePath != nil ? 1 : 0)
        guard payloadCount == 1 else {
            return .failure("expected exactly one of activity/visit/timelinePath, got \(payloadCount)")
        }

        let kind: EventKind
        let payloadDigest: String
        if let activity = record.activity {
            switch convert(activity: activity) {
            case let .success(details): kind = .activity(details)
            case let .failure(reason): return .failure(reason)
            }
            payloadDigest = "\(activity.start)|\(activity.end)|\(activity.distanceMeters)|\(activity.topCandidate.type)"
        } else if let visit = record.visit {
            switch convert(visit: visit) {
            case let .success(details): kind = .visit(details)
            case let .failure(reason): return .failure(reason)
            }
            payloadDigest = "\(visit.topCandidate.placeID)|\(visit.topCandidate.placeLocation)"
        } else if let path = record.timelinePath {
            switch convert(path: path) {
            case let .success(points): kind = .path(points)
            case let .failure(reason): return .failure(reason)
            }
            payloadDigest = "path:\(path.count):\(path.first?.point ?? "")>\(path.last?.point ?? "")"
        } else {
            return .failure("unreachable: payload count guard passed but no payload matched")
        }

        // Derive a deterministic id from source|kind|start|end|payload so re-importing the same
        // (or an overlapping) Takeout file produces identical ids and the writer can dedupe (H5).
        let id = Self.deterministicID(
            source: Core.googleTakeoutSourceTag,
            kind: kind.discriminator,
            startTime: record.startTime,
            endTime: record.endTime,
            payloadDigest: payloadDigest
        )

        return .success(Event(
            id: id,
            start: start,
            end: end,
            source: Core.googleTakeoutSourceTag,
            kind: kind
        ))
    }

    private func convert(activity: Wire.ActivityPayload) -> ConversionOutcome<ActivityDetails> {
        guard let start = Coordinate.parse(geoURI: activity.start) else {
            return .failure("unparseable activity.start '\(activity.start)'")
        }
        guard let end = Coordinate.parse(geoURI: activity.end) else {
            return .failure("unparseable activity.end '\(activity.end)'")
        }
        guard let rawDistance = Double(activity.distanceMeters), rawDistance.isFinite else {
            return .failure("unparseable activity.distanceMeters '\(activity.distanceMeters)'")
        }
        let probability = sanitized(Double(activity.topCandidate.probability))
        return .success(ActivityDetails(
            start: start,
            end: end,
            distanceMeters: rawDistance,
            mode: activity.topCandidate.type,
            probability: probability
        ))
    }

    private func convert(visit: Wire.VisitPayload) -> ConversionOutcome<VisitDetails> {
        guard let location = Coordinate.parse(geoURI: visit.topCandidate.placeLocation) else {
            return .failure("unparseable visit.placeLocation '\(visit.topCandidate.placeLocation)'")
        }
        let hierarchyLevel = Int(visit.hierarchyLevel) ?? 0
        let probability = sanitized(Double(visit.probability))
        return .success(VisitDetails(
            placeID: visit.topCandidate.placeID,
            location: location,
            semanticType: visit.topCandidate.semanticType,
            hierarchyLevel: hierarchyLevel,
            probability: probability
        ))
    }

    private func convert(path: [Wire.TimelinePoint]) -> ConversionOutcome<[PathPoint]> {
        // An empty timelinePath would produce a point-less path event, violating the
        // downstream >=1-sample invariant — skip it instead (L52).
        guard !path.isEmpty else {
            return .failure("empty timelinePath")
        }
        var points: [PathPoint] = []
        points.reserveCapacity(path.count)
        for (i, wire) in path.enumerated() {
            guard let coordinate = Coordinate.parse(geoURI: wire.point) else {
                return .failure("unparseable timelinePath[\(i)].point '\(wire.point)'")
            }
            guard let offset = Int(wire.durationMinutesOffsetFromStartTime) else {
                return .failure(
                    "unparseable timelinePath[\(i)].durationMinutesOffsetFromStartTime "
                        + "'\(wire.durationMinutesOffsetFromStartTime)'"
                )
            }
            points.append(PathPoint(coordinate: coordinate, offsetMinutes: offset))
        }
        return .success(points)
    }

    // MARK: - Helpers

    /// Maps a parsed double to a finite value, replacing `nil`/`nan`/`inf` (which `Double("nan")`
    /// and `Double("inf")` happily produce) with `0` so a junk probability/distance can't reach
    /// the DB as a non-finite value and abort the import on a NOT NULL/binding error (L50).
    private func sanitized(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return value
    }

    /// Deterministic UUIDv5 over a stable string, using the SHA-1 namespace-hash construction.
    static func deterministicID(
        source: String,
        kind: String,
        startTime: String,
        endTime: String,
        payloadDigest: String
    ) -> UUID {
        let name = "\(source)|\(kind)|\(startTime)|\(endTime)|\(payloadDigest)"
        // Fixed namespace UUID for RememberMe Takeout events (random, stable forever).
        let namespace: [UInt8] = [
            0x8B, 0x1E, 0x3F, 0x42, 0x9C, 0x7D, 0x4A, 0x55,
            0xB0, 0x12, 0x6E, 0x88, 0xC3, 0x41, 0x2A, 0x9F,
        ]
        var hasher = Insecure.SHA1()
        hasher.update(data: Data(namespace))
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        // Set the version (5) and RFC 4122 variant bits.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
