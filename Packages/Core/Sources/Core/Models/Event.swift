import Foundation

/// A single thing that happened in your timeline: a trip, a visit, or a raw GPS breadcrumb segment.
public struct Event: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let start: TimestampedLocal
    public let end: TimestampedLocal
    /// Free-form provenance string (e.g. `"google-takeout-ios-v1"`).
    public let source: String
    public let kind: EventKind

    public init(
        id: UUID = UUID(),
        start: TimestampedLocal,
        end: TimestampedLocal,
        source: String,
        kind: EventKind
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.source = source
        self.kind = kind
    }
}
