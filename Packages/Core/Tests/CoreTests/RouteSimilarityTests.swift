import XCTest
@testable import Core

final class RouteSimilarityTests: XCTestCase {
    func testIdenticalPolylinesScoreNearZero() throws {
        let line = [
            Coordinate(latitude: 48.8566, longitude: 2.3522),
            Coordinate(latitude: 48.8576, longitude: 2.3532),
            Coordinate(latitude: 48.8586, longitude: 2.3542),
        ]
        let score = try XCTUnwrap(RouteSimilarity.score(samples: line, candidate: line))
        XCTAssertEqual(score.meanMeters, 0, accuracy: 0.01)
        XCTAssertEqual(score.p95Meters, 0, accuracy: 0.01)
        XCTAssertEqual(score.maxMeters, 0, accuracy: 0.01)
        XCTAssertEqual(score.sampleCount, 3)
        // Fit is perfect, so composite is purely the 0.01 * length tie-breaker term.
        XCTAssertEqual(score.composite, 0.01 * score.candidateLengthMeters, accuracy: 0.01)
    }

    func testParallelOffsetScoresApproximateOffsetDistance() throws {
        // Candidate runs along a meridian; samples run 10 m east.
        let candidate = [
            Coordinate(latitude: 48.86, longitude: 2.35),
            Coordinate(latitude: 48.87, longitude: 2.35),
        ]
        // 10 m east at 48.86° lat ≈ 0.000137° in longitude.
        let offsetLon = 0.000_137
        let samples = [
            Coordinate(latitude: 48.862, longitude: 2.35 + offsetLon),
            Coordinate(latitude: 48.864, longitude: 2.35 + offsetLon),
            Coordinate(latitude: 48.866, longitude: 2.35 + offsetLon),
        ]
        let score = try XCTUnwrap(RouteSimilarity.score(samples: samples, candidate: candidate))
        XCTAssertEqual(score.meanMeters, 10, accuracy: 1.0)
        XCTAssertEqual(score.p95Meters, 10, accuracy: 1.0)
        XCTAssertEqual(score.maxMeters, 10, accuracy: 1.0)
    }

    func testPerpendicularCrossingHasOneZeroSample() throws {
        // Candidate along a meridian; one sample sits directly on the line, others 50 m east.
        let candidate = [
            Coordinate(latitude: 48.86, longitude: 2.35),
            Coordinate(latitude: 48.87, longitude: 2.35),
        ]
        let offsetLon = 50 * 0.000_0137 // ~50 m east at this latitude.
        let samples = [
            Coordinate(latitude: 48.862, longitude: 2.35 + offsetLon),
            Coordinate(latitude: 48.864, longitude: 2.35),
            Coordinate(latitude: 48.866, longitude: 2.35 + offsetLon),
        ]
        let score = try XCTUnwrap(RouteSimilarity.score(samples: samples, candidate: candidate))
        XCTAssertEqual(score.maxMeters, 50, accuracy: 5.0)
        XCTAssertLessThan(score.meanMeters, 50)
    }

    func testPartialOverlapMatchesSampledPortionTightly() throws {
        // 4 samples directly on the candidate, 1 sample 100 m off the end.
        let candidate = [
            Coordinate(latitude: 48.86, longitude: 2.35),
            Coordinate(latitude: 48.87, longitude: 2.35),
        ]
        let onLine = [
            Coordinate(latitude: 48.862, longitude: 2.35),
            Coordinate(latitude: 48.864, longitude: 2.35),
            Coordinate(latitude: 48.866, longitude: 2.35),
            Coordinate(latitude: 48.868, longitude: 2.35),
        ]
        let offLine = Coordinate(latitude: 48.870, longitude: 2.35 + 100 * 0.000_0137)
        let samples = onLine + [offLine]
        let score = try XCTUnwrap(RouteSimilarity.score(samples: samples, candidate: candidate))
        XCTAssertLessThan(score.meanMeters, 50)
        XCTAssertGreaterThan(score.maxMeters, 80)
    }

    func testNoOverlapHasLargeDistances() throws {
        // Candidate near (0,0); samples near (1,1) — hundreds of km away.
        let candidate = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0.001, longitude: 0),
        ]
        let samples = [
            Coordinate(latitude: 1, longitude: 1),
            Coordinate(latitude: 1.001, longitude: 1.001),
        ]
        let score = try XCTUnwrap(RouteSimilarity.score(samples: samples, candidate: candidate))
        XCTAssertGreaterThan(score.meanMeters, 100_000)
    }

    func testEmptySamplesReturnsNil() {
        let candidate = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0.001, longitude: 0),
        ]
        XCTAssertNil(RouteSimilarity.score(samples: [], candidate: candidate))
    }

    func testPercentileLinearInterpolation() {
        let values: [Double] = [1, 2, 3, 4, 5]
        XCTAssertEqual(RouteSimilarity.percentile(values, p: 0), 1)
        XCTAssertEqual(RouteSimilarity.percentile(values, p: 1), 5)
        XCTAssertEqual(RouteSimilarity.percentile(values, p: 0.5), 3)
    }

    func testNearestPointDistanceIsSmallAcrossTheAntimeridian() {
        // A sample and segment a few km apart but on opposite sides of the 180th meridian.
        // Without normalizing the longitude delta this projects ~40,000 km instead of ~km.
        let distance = RouteSimilarity.nearestPointDistance(
            point: Coordinate(latitude: 0, longitude: 179.99),
            segmentStart: Coordinate(latitude: 0, longitude: -179.99),
            segmentEnd: Coordinate(latitude: 0.01, longitude: -179.99)
        )
        XCTAssertLessThan(distance, 5_000, "antimeridian-straddling distance should be a few km, not half the globe")
    }

    func testLengthTieBreakerPrefersShorterCandidateOnEqualFit() throws {
        // Two candidates both pass exactly through the recorded samples (zero fit distance), but
        // one detours far north and back. The length tie-breaker must rank the direct one lower.
        let samples = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 0.01),
            Coordinate(latitude: 0, longitude: 0.02),
        ]
        let direct = samples
        let detour = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0.5, longitude: 0.005), // big northward excursion through unsampled space
            Coordinate(latitude: 0, longitude: 0.01),
            Coordinate(latitude: 0, longitude: 0.02),
        ]
        let directScore = try XCTUnwrap(RouteSimilarity.score(samples: samples, candidate: direct))
        let detourScore = try XCTUnwrap(RouteSimilarity.score(samples: samples, candidate: detour))
        // Both fit the samples well (every sample lies on each candidate), so fit alone wouldn't
        // distinguish them — the length term must.
        XCTAssertGreaterThan(detourScore.candidateLengthMeters, directScore.candidateLengthMeters)
        XCTAssertLessThan(directScore.composite, detourScore.composite)
    }
}
