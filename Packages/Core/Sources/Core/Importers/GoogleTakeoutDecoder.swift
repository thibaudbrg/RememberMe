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

    public enum DecodeError: Error, CustomStringConvertible {
        case malformedJSON(underlying: Error)

        public var description: String {
            switch self {
            case let .malformedJSON(underlying): "malformed Takeout JSON: \(underlying)"
            }
        }
    }

    public init() {}

    /// Internal result-like enum, used because `Swift.Result` requires `Failure: Error`
    /// and our failure case is just a human-readable string we attach to a skip report.
    private enum ConversionOutcome<Value> {
        case success(Value)
        case failure(String)
    }

    public func decode(_ data: Data) throws -> Result {
        let records: [Wire.Record]
        do {
            records = try JSONDecoder().decode([Wire.Record].self, from: data)
        } catch {
            throw DecodeError.malformedJSON(underlying: error)
        }

        var events: [Event] = []
        events.reserveCapacity(records.count)
        var skipped: [SkipReason] = []

        for (index, record) in records.enumerated() {
            switch convert(record: record) {
            case let .success(event): events.append(event)
            case let .failure(reason): skipped.append(SkipReason(recordIndex: index, reason: reason))
            }
        }

        return Result(events: events, skipped: skipped)
    }

    // MARK: - Per-record conversion

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
        if let activity = record.activity {
            switch convert(activity: activity) {
            case let .success(details): kind = .activity(details)
            case let .failure(reason): return .failure(reason)
            }
        } else if let visit = record.visit {
            switch convert(visit: visit) {
            case let .success(details): kind = .visit(details)
            case let .failure(reason): return .failure(reason)
            }
        } else if let path = record.timelinePath {
            switch convert(path: path) {
            case let .success(points): kind = .path(points)
            case let .failure(reason): return .failure(reason)
            }
        } else {
            return .failure("unreachable: payload count guard passed but no payload matched")
        }

        return .success(Event(
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
        guard let distance = Double(activity.distanceMeters) else {
            return .failure("unparseable activity.distanceMeters '\(activity.distanceMeters)'")
        }
        let probability = Double(activity.topCandidate.probability) ?? 0
        return .success(ActivityDetails(
            start: start,
            end: end,
            distanceMeters: distance,
            mode: activity.topCandidate.type,
            probability: probability
        ))
    }

    private func convert(visit: Wire.VisitPayload) -> ConversionOutcome<VisitDetails> {
        guard let location = Coordinate.parse(geoURI: visit.topCandidate.placeLocation) else {
            return .failure("unparseable visit.placeLocation '\(visit.topCandidate.placeLocation)'")
        }
        let hierarchyLevel = Int(visit.hierarchyLevel) ?? 0
        let probability = Double(visit.probability) ?? 0
        return .success(VisitDetails(
            placeID: visit.topCandidate.placeID,
            location: location,
            semanticType: visit.topCandidate.semanticType,
            hierarchyLevel: hierarchyLevel,
            probability: probability
        ))
    }

    private func convert(path: [Wire.TimelinePoint]) -> ConversionOutcome<[PathPoint]> {
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
}
