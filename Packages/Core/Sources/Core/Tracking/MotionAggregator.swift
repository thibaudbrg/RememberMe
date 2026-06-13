import Foundation

/// Platform-agnostic shadow of `CMMotionActivity`. The iOS-side runtime
/// converts each CoreMotion update into one of these and feeds it into
/// `MotionAggregator`. Keeps the aggregation logic testable on any platform.
public struct MotionSample: Sendable, Equatable {
    public let walking: Bool
    public let running: Bool
    public let cycling: Bool
    public let automotive: Bool
    public let stationary: Bool
    public let confidence: Confidence

    public enum Confidence: Int, Sendable, Equatable, Comparable {
        case low = 1
        case medium = 2
        case high = 3
        public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
    }

    public init(
        walking: Bool = false,
        running: Bool = false,
        cycling: Bool = false,
        automotive: Bool = false,
        stationary: Bool = false,
        confidence: Confidence = .low
    ) {
        self.walking = walking
        self.running = running
        self.cycling = cycling
        self.automotive = automotive
        self.stationary = stationary
        self.confidence = confidence
    }
}

/// Confidence-weighted vote tally over a trip's motion samples. Produces a
/// single dominant mode + a normalised confidence in `[0, 1]` when the trip
/// closes. Stationary samples are deliberately ignored — they don't tell us
/// what kind of motion happened; only the moving samples do.
///
/// Mode strings match the Google Takeout `topCandidate.type` vocabulary so
/// live-tracked trips look identical to imported ones in the UI:
/// `"walking"`, `"running"`, `"cycling"`, `"in passenger vehicle"`, `"unknown"`.
public struct MotionAggregator: Sendable, Equatable {
    public static let walking = "walking"
    public static let running = "running"
    public static let cycling = "cycling"
    public static let inPassengerVehicle = "in passenger vehicle"
    public static let unknown = "unknown"

    private var votes: [String: Double] = [:]
    private(set) public var sampleCount: Int = 0

    public init() {}

    public mutating func record(_ sample: MotionSample) {
        sampleCount += 1
        let weight = Double(sample.confidence.rawValue)
        if sample.walking { votes[Self.walking, default: 0] += weight }
        if sample.running { votes[Self.running, default: 0] += weight }
        if sample.cycling { votes[Self.cycling, default: 0] += weight }
        if sample.automotive { votes[Self.inPassengerVehicle, default: 0] += weight }
        // stationary: ignored on purpose — see doc comment.
    }

    /// Returns the dominant mode and a normalised probability in `[0, 1]`. The
    /// probability is the share of total motion-weighted votes the winner got.
    /// If there were no motion samples at all (only stationary, or none), the
    /// result is `(unknown, 0)`.
    public func dominantMode() -> (mode: String, probability: Double) {
        guard !votes.isEmpty else { return (Self.unknown, 0) }
        let total = votes.values.reduce(0, +)
        guard total > 0 else { return (Self.unknown, 0) }
        // Deterministic winner: highest vote weight, ties broken by a fixed mode
        // priority so the result never depends on Dictionary iteration order.
        let top = votes.max { a, b in
            if a.value != b.value { return a.value < b.value }
            return Self.tieBreakRank(a.key) > Self.tieBreakRank(b.key)
        }!
        return (top.key, top.value / total)
    }

    /// Lower rank wins ties. Order is arbitrary but fixed — what matters is that
    /// equal-weight modes always resolve to the same winner across runs.
    private static func tieBreakRank(_ mode: String) -> Int {
        switch mode {
        case inPassengerVehicle: return 0
        case cycling: return 1
        case running: return 2
        case walking: return 3
        default: return 4
        }
    }
}
