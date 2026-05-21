import Foundation

public enum Core {
    /// Persistence schema version this build of Core is paired with.
    /// Bump in lockstep with `Persistence` when the on-disk schema changes.
    public static let schemaVersion = 1

    /// Source string written into `events.source` for records produced by `GoogleTakeoutDecoder`.
    public static let googleTakeoutSourceTag = "google-takeout-ios-v1"
}
