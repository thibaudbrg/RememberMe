import Foundation

/// A timestamp that remembers both the UTC instant and the local timezone offset
/// that was in effect at that instant. We keep the offset so the timeline UI can
/// show "I was in Paris at 3pm Paris time" regardless of where the user is now.
public struct TimestampedLocal: Hashable, Sendable, Codable {
    /// UTC instant.
    public let date: Date
    /// Offset from UTC, in whole minutes (e.g. `+120` for `+02:00`, `-300` for `-05:00`).
    public let tzOffsetMinutes: Int

    public init(date: Date, tzOffsetMinutes: Int) {
        self.date = date
        self.tzOffsetMinutes = tzOffsetMinutes
    }
}

extension TimestampedLocal {
    /// Formatter for timestamps with fractional seconds (the common Takeout case). Hoisted so
    /// large imports don't allocate a fresh `ISO8601DateFormatter` per record.
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Fallback formatter for records that omit fractional seconds.
    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parse an ISO 8601 timestamp with offset, e.g. `"2023-08-23T07:52:01.117+02:00"` or `"2024-01-15T08:00:00.000Z"`.
    /// Returns `nil` on malformed input.
    public static func parse(iso8601: String) -> TimestampedLocal? {
        if let date = fractionalFormatter.date(from: iso8601) {
            return TimestampedLocal(date: date, tzOffsetMinutes: extractOffsetMinutes(from: iso8601))
        }
        // Try again without fractional seconds (some records omit them).
        guard let fallback = plainFormatter.date(from: iso8601) else { return nil }
        return TimestampedLocal(date: fallback, tzOffsetMinutes: extractOffsetMinutes(from: iso8601))
    }

    private static func extractOffsetMinutes(from iso8601: String) -> Int {
        // Trailing "Z" = UTC.
        if iso8601.hasSuffix("Z") { return 0 }
        // Look for "+HH:MM" or "-HH:MM" at the very end.
        let chars = Array(iso8601)
        guard chars.count >= 6 else { return 0 }
        let tail = String(chars.suffix(6))
        guard tail.count == 6,
              let sign = tail.first,
              sign == "+" || sign == "-",
              tail[tail.index(tail.startIndex, offsetBy: 3)] == ":"
        else {
            return 0
        }
        let hhStart = tail.index(tail.startIndex, offsetBy: 1)
        let hhEnd = tail.index(hhStart, offsetBy: 2)
        let mmStart = tail.index(hhEnd, offsetBy: 1)
        let mmEnd = tail.endIndex
        guard let hours = Int(tail[hhStart ..< hhEnd]),
              let minutes = Int(tail[mmStart ..< mmEnd])
        else {
            return 0
        }
        let total = hours * 60 + minutes
        return sign == "+" ? total : -total
    }
}
