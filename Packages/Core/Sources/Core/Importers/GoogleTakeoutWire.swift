import Foundation

/// Codable types that exactly mirror the Google Takeout iOS-format JSON.
/// These are internal to the decoder — the public API exposes domain types (`Event`, etc.) only.
enum Wire {}

extension Wire {
    /// A single top-level record. Exactly one of `activity` / `visit` / `timelinePath` is set.
    struct Record: Decodable {
        let startTime: String
        let endTime: String
        let activity: ActivityPayload?
        let visit: VisitPayload?
        let timelinePath: [TimelinePoint]?
    }

    struct ActivityPayload: Decodable {
        let start: String
        let end: String
        let distanceMeters: String
        let topCandidate: ActivityCandidate
    }

    struct ActivityCandidate: Decodable {
        let type: String
        let probability: String
    }

    struct VisitPayload: Decodable {
        let hierarchyLevel: String
        let probability: String
        let topCandidate: VisitCandidate
    }

    struct VisitCandidate: Decodable {
        let placeID: String
        let placeLocation: String
        let semanticType: String
        let probability: String
    }

    struct TimelinePoint: Decodable {
        let point: String
        let durationMinutesOffsetFromStartTime: String
    }
}
