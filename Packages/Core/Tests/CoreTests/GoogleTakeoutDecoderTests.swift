import XCTest
@testable import Core

final class GoogleTakeoutDecoderTests: XCTestCase {
    func testDecodesFixtureWithOneOfEachKind() throws {
        let data = try loadFixture(named: "google-takeout-minimal")
        let result = try GoogleTakeoutDecoder().decode(data)

        XCTAssertEqual(result.events.count, 3)
        XCTAssertEqual(result.skipped.count, 0, "no records should be skipped: \(result.skipped)")

        let kinds = result.events.map(\.kind.discriminator)
        XCTAssertEqual(Set(kinds), Set(["activity", "visit", "path"]))
    }

    func testDecodesActivityFields() throws {
        let data = try loadFixture(named: "google-takeout-minimal")
        let events = try GoogleTakeoutDecoder().decode(data).events

        guard let event = events.first(where: { $0.kind.discriminator == "activity" }),
              case let .activity(details) = event.kind
        else {
            return XCTFail("expected one activity event")
        }

        XCTAssertEqual(details.start.latitude, 0.0)
        XCTAssertEqual(details.start.longitude, 0.0)
        XCTAssertEqual(details.end.latitude, 0.01)
        XCTAssertEqual(details.end.longitude, 0.01)
        XCTAssertEqual(details.distanceMeters, 1572.0)
        XCTAssertEqual(details.mode, "walking")
        XCTAssertEqual(details.probability, 0.9)
        XCTAssertEqual(event.source, Core.googleTakeoutSourceTag)
    }

    func testDecodesVisitFields() throws {
        let data = try loadFixture(named: "google-takeout-minimal")
        let events = try GoogleTakeoutDecoder().decode(data).events

        guard let event = events.first(where: { $0.kind.discriminator == "visit" }),
              case let .visit(details) = event.kind
        else {
            return XCTFail("expected one visit event")
        }

        XCTAssertEqual(details.placeID, "FIXTURE_PLACE_ALPHA")
        XCTAssertEqual(details.location.latitude, 0.01)
        XCTAssertEqual(details.location.longitude, 0.01)
        XCTAssertEqual(details.semanticType, "Work")
        XCTAssertEqual(details.hierarchyLevel, 0)
        XCTAssertEqual(details.probability, 0.95)
    }

    func testDecodesPathFields() throws {
        let data = try loadFixture(named: "google-takeout-minimal")
        let events = try GoogleTakeoutDecoder().decode(data).events

        guard let event = events.first(where: { $0.kind.discriminator == "path" }),
              case let .path(points) = event.kind
        else {
            return XCTFail("expected one path event")
        }

        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points.first?.offsetMinutes, 0)
        XCTAssertEqual(points.last?.offsetMinutes, 30)
        XCTAssertEqual(points.last?.coordinate.latitude, 0.02)
    }

    func testThrowsOnGarbageJSON() {
        XCTAssertThrowsError(try GoogleTakeoutDecoder().decode(Data("not json".utf8))) { error in
            guard case GoogleTakeoutDecoder.DecodeError.malformedJSON = error else {
                return XCTFail("expected .malformedJSON, got \(error)")
            }
        }
    }

    func testSkipsRecordWithMultiplePayloads() throws {
        // Hand-roll a record with BOTH activity and visit set — decoder should skip it.
        let jsonString = """
        [
          {
            "startTime": "2024-01-15T08:00:00.000Z",
            "endTime":   "2024-01-15T09:00:00.000Z",
            "activity":  { "start": "geo:0,0", "end": "geo:1,1", "distanceMeters": "100",
                           "topCandidate": { "type": "walking", "probability": "0.5" } },
            "visit":     { "hierarchyLevel": "0", "probability": "0.9",
                           "topCandidate": { "placeID": "X", "placeLocation": "geo:0,0",
                                             "semanticType": "Home", "probability": "0.9" } }
          }
        ]
        """
        let result = try GoogleTakeoutDecoder().decode(Data(jsonString.utf8))
        XCTAssertEqual(result.events.count, 0)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.skipped[0].reason.contains("exactly one"))
    }

    // MARK: - Deterministic IDs (H5)

    func testDecodingSameDataTwiceProducesIdenticalEventIDs() throws {
        let data = try loadFixture(named: "google-takeout-minimal")
        let first = try GoogleTakeoutDecoder().decode(data).events
        let second = try GoogleTakeoutDecoder().decode(data).events
        XCTAssertEqual(first.map(\.id), second.map(\.id), "re-decoding must yield stable ids for idempotent import")
    }

    func testDistinctRecordsGetDistinctIDs() throws {
        let data = try loadFixture(named: "google-takeout-minimal")
        let ids = try GoogleTakeoutDecoder().decode(data).events.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "each record should hash to a unique id")
    }

    // MARK: - Lossy per-record decoding (M29)

    func testMalformedRecordSkippedNotAborted() throws {
        // First record is schema-broken (activity.start is a number, not a string); the two
        // following well-formed records must still decode.
        let jsonString = """
        [
          { "startTime": "2024-01-15T08:00:00.000Z", "endTime": "2024-01-15T09:00:00.000Z",
            "activity": { "start": 12345, "end": "geo:1,1", "distanceMeters": "100",
                          "topCandidate": { "type": "walking", "probability": "0.5" } } },
          { "startTime": "2024-01-15T09:00:00.000Z", "endTime": "2024-01-15T17:00:00.000Z",
            "visit": { "hierarchyLevel": "0", "probability": "0.9",
                       "topCandidate": { "placeID": "X", "placeLocation": "geo:0,0",
                                         "semanticType": "Home", "probability": "0.9" } } },
          { "startTime": "2024-01-15T17:00:00.000Z", "endTime": "2024-01-15T17:30:00.000Z",
            "timelinePath": [ { "point": "geo:0,0", "durationMinutesOffsetFromStartTime": "0" } ] }
        ]
        """
        let result = try GoogleTakeoutDecoder().decode(Data(jsonString.utf8))
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(result.skipped.first?.recordIndex, 0)
    }

    // MARK: - Streaming decode (M28)

    func testStreamingProducesSameEventsAsDecode() throws {
        let data = try loadFixture(named: "google-takeout-minimal")
        let nonStreaming = try GoogleTakeoutDecoder().decode(data)

        var streamed: [Event] = []
        let skipped = try GoogleTakeoutDecoder().decodeStreaming(data, batchSize: 1) { batch in
            streamed.append(contentsOf: batch)
        }
        XCTAssertEqual(streamed.map(\.id), nonStreaming.events.map(\.id))
        XCTAssertEqual(skipped.count, nonStreaming.skipped.count)
    }

    func testStreamingBatchesAreNonEmptyAndChunked() throws {
        let data = try loadFixture(named: "google-takeout-minimal")
        var batchSizes: [Int] = []
        _ = try GoogleTakeoutDecoder().decodeStreaming(data, batchSize: 2) { batch in
            XCTAssertFalse(batch.isEmpty)
            batchSizes.append(batch.count)
        }
        XCTAssertEqual(batchSizes.reduce(0, +), 3)
    }

    // MARK: - Unsupported format (L46) + LocalizedError (L48)

    func testRejectsAndroidWebTakeoutShape() {
        let json = Data(#"{"semanticSegments": [], "rawSignals": []}"#.utf8)
        XCTAssertThrowsError(try GoogleTakeoutDecoder().decode(json)) { error in
            guard case let GoogleTakeoutDecoder.DecodeError.unsupportedFormat(detail) = error else {
                return XCTFail("expected .unsupportedFormat, got \(error)")
            }
            XCTAssertTrue(detail.contains("semanticSegments"))
        }
    }

    func testDecodeErrorIsLocalized() {
        let error: Error = GoogleTakeoutDecoder.DecodeError.unsupportedFormat(detail: "nope")
        XCTAssertEqual((error as NSError).localizedDescription, "nope")
        XCTAssertFalse((error as NSError).localizedDescription.contains("error 0"))
    }

    // MARK: - Non-finite sanitisation (L50)

    func testNonFiniteProbabilityAndDistanceAreSanitised() throws {
        // probability "nan" -> 0; distanceMeters "inf" must be rejected (a non-finite distance
        // is not a recoverable value), so the record is skipped rather than written as junk.
        let nanProb = """
        [ { "startTime": "2024-01-15T08:00:00.000Z", "endTime": "2024-01-15T09:00:00.000Z",
            "activity": { "start": "geo:0,0", "end": "geo:1,1", "distanceMeters": "100",
                          "topCandidate": { "type": "walking", "probability": "nan" } } } ]
        """
        let nanResult = try GoogleTakeoutDecoder().decode(Data(nanProb.utf8))
        guard case let .activity(details)? = nanResult.events.first?.kind else {
            return XCTFail("expected one activity event")
        }
        XCTAssertEqual(details.probability, 0)
        XCTAssertTrue(details.distanceMeters.isFinite)

        let infDistance = """
        [ { "startTime": "2024-01-15T08:00:00.000Z", "endTime": "2024-01-15T09:00:00.000Z",
            "activity": { "start": "geo:0,0", "end": "geo:1,1", "distanceMeters": "inf",
                          "topCandidate": { "type": "walking", "probability": "0.5" } } } ]
        """
        let infResult = try GoogleTakeoutDecoder().decode(Data(infDistance.utf8))
        XCTAssertEqual(infResult.events.count, 0)
        XCTAssertEqual(infResult.skipped.count, 1)
    }

    // MARK: - Empty path (L52)

    func testEmptyTimelinePathIsSkipped() throws {
        let json = """
        [ { "startTime": "2024-01-15T17:00:00.000Z", "endTime": "2024-01-15T17:30:00.000Z",
            "timelinePath": [] } ]
        """
        let result = try GoogleTakeoutDecoder().decode(Data(json.utf8))
        XCTAssertEqual(result.events.count, 0)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.skipped[0].reason.contains("empty timelinePath"))
    }

    // MARK: - Real-data smoke test (skipped if the file isn't on disk)

    func testDecodesRealLocationHistoryIfPresent() throws {
        guard let url = realLocationHistoryURL() else {
            throw XCTSkip("sample-data/google-takeout/location-history.json not present; skipping real-data test")
        }
        let data = try Data(contentsOf: url)
        let result = try GoogleTakeoutDecoder().decode(data)
        XCTAssertGreaterThan(result.events.count, 0, "real Takeout file should produce > 0 events")
        // We tolerate a small number of skips (records can be wonky in real exports) but the
        // overwhelming majority should decode.
        let skipRatio = Double(result.skipped.count) / Double(result.events.count + result.skipped.count)
        XCTAssertLessThan(skipRatio, 0.05, "more than 5% of real records were skipped: \(result.skipped.count) skipped")
    }

    // MARK: - Helpers

    private func loadFixture(named name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw NSError(
                domain: "GoogleTakeoutDecoderTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "fixture \(name).json not found in test bundle"]
            )
        }
        return try Data(contentsOf: url)
    }

    /// Walk up from the test bundle to the repo root, then look for the real file. Returns nil if it's not there.
    private func realLocationHistoryURL() -> URL? {
        // Bundle.module lives somewhere inside Packages/Core/.build/... — walk up until we see the repo's
        // `sample-data/`.
        var dir = Bundle.module.bundleURL
        for _ in 0 ..< 12 {
            let candidate = dir.appendingPathComponent("sample-data/google-takeout/location-history.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
