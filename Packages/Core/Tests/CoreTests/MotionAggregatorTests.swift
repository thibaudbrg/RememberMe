import XCTest
@testable import Core

final class MotionAggregatorTests: XCTestCase {
    func testEmptyAggregatorReturnsUnknown() {
        let agg = MotionAggregator()
        let result = agg.dominantMode()
        XCTAssertEqual(result.mode, "unknown")
        XCTAssertEqual(result.probability, 0.0)
    }

    func testStationaryOnlyReturnsUnknown() {
        var agg = MotionAggregator()
        agg.record(MotionSample(stationary: true, confidence: .high))
        agg.record(MotionSample(stationary: true, confidence: .medium))
        let result = agg.dominantMode()
        XCTAssertEqual(result.mode, "unknown")
        XCTAssertEqual(result.probability, 0.0)
    }

    func testSingleWalkingSampleReturnsWalkingFullProbability() {
        var agg = MotionAggregator()
        agg.record(MotionSample(walking: true, confidence: .high))
        let result = agg.dominantMode()
        XCTAssertEqual(result.mode, "walking")
        XCTAssertEqual(result.probability, 1.0, accuracy: 0.0001)
    }

    func testWalkingDominantOverScatteredAutomotive() {
        var agg = MotionAggregator()
        for _ in 0..<10 {
            agg.record(MotionSample(walking: true, confidence: .high))
        }
        agg.record(MotionSample(automotive: true, confidence: .low))
        let result = agg.dominantMode()
        XCTAssertEqual(result.mode, "walking")
        XCTAssertGreaterThan(result.probability, 0.9)
    }

    func testConfidenceWeighting() {
        // 3 low-confidence walking vs. 1 high-confidence automotive.
        // Walking: 3 votes × 1 weight = 3. Automotive: 1 × 3 = 3. Tie.
        // The deterministic tie-break ranks automotive ahead of walking, so the
        // winner is stable across runs — assert it explicitly.
        var agg = MotionAggregator()
        agg.record(MotionSample(walking: true, confidence: .low))
        agg.record(MotionSample(walking: true, confidence: .low))
        agg.record(MotionSample(walking: true, confidence: .low))
        agg.record(MotionSample(automotive: true, confidence: .high))
        let result = agg.dominantMode()
        XCTAssertEqual(result.mode, "in passenger vehicle")
        XCTAssertEqual(result.probability, 0.5, accuracy: 0.0001)
    }

    func testTieBreakIsDeterministicRegardlessOfInsertionOrder() {
        // Same two modes tied, recorded in the opposite order — the tie-break
        // must still pick the same winner (no Dictionary-order dependence).
        var agg = MotionAggregator()
        agg.record(MotionSample(automotive: true, confidence: .high))
        agg.record(MotionSample(walking: true, confidence: .low))
        agg.record(MotionSample(walking: true, confidence: .low))
        agg.record(MotionSample(walking: true, confidence: .low))
        let result = agg.dominantMode()
        XCTAssertEqual(result.mode, "in passenger vehicle")
        XCTAssertEqual(result.probability, 0.5, accuracy: 0.0001)
    }

    func testAutomotiveDominant() {
        var agg = MotionAggregator()
        for _ in 0..<5 {
            agg.record(MotionSample(automotive: true, confidence: .high))
        }
        let result = agg.dominantMode()
        XCTAssertEqual(result.mode, "in passenger vehicle")
        XCTAssertEqual(result.probability, 1.0, accuracy: 0.0001)
    }

    func testMultipleBitsOnSameSampleEachGetsVote() {
        // CMMotionActivity bits aren't mutually exclusive — a single sample can
        // have walking+automotive when the user is on a bus and the classifier
        // is uncertain. The aggregator awards a vote to every set bit. The tie
        // (each gets 0.5) resolves deterministically to automotive.
        var agg = MotionAggregator()
        agg.record(MotionSample(walking: true, automotive: true, confidence: .medium))
        let result = agg.dominantMode()
        XCTAssertEqual(result.mode, "in passenger vehicle")
        XCTAssertEqual(result.probability, 0.5, accuracy: 0.0001)
    }

    func testSampleCountTracksAllRecordedSamples() {
        var agg = MotionAggregator()
        agg.record(MotionSample(walking: true, confidence: .high))
        agg.record(MotionSample(stationary: true, confidence: .high))
        agg.record(MotionSample(automotive: true, confidence: .low))
        XCTAssertEqual(agg.sampleCount, 3)
    }
}
