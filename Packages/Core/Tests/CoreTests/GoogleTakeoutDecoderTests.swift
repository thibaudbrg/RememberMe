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
