import Core
import Foundation

/// Inserts `[Event]` into the persistence layer in batched transactions.
/// Tunable batch size (default 500) keeps memory usage flat on multi-MB imports.
public final class EventWriter: Sendable {
    public static let defaultBatchSize = 500

    private let database: SQLCipherDatabase
    private let batchSize: Int

    public init(database: SQLCipherDatabase, batchSize: Int = defaultBatchSize) {
        self.database = database
        self.batchSize = batchSize
    }

    /// Inserts every event. The entire run is wrapped in a single transaction so a mid-import
    /// failure leaves nothing committed — the offered "Try again" then re-imports from a clean
    /// slate instead of duplicating a partial write. Returns the number of events written.
    @discardableResult
    public func write(_ events: [Event], importedAt: Date = Date()) throws -> Int {
        guard !events.isEmpty else { return 0 }
        var written = 0
        let importedAtUnix = Int64(importedAt.timeIntervalSince1970)
        try database.transaction {
            var index = 0
            while index < events.count {
                let upper = min(index + batchSize, events.count)
                let slice = events[index ..< upper]
                try insertSlice(slice, importedAt: importedAtUnix)
                written += slice.count
                index = upper
            }
        }
        return written
    }

    // MARK: - Internals

    private func insertSlice(_ slice: ArraySlice<Event>, importedAt: Int64) throws {
        let eventStmt = try database.prepare("""
            INSERT OR IGNORE INTO events
                (id, kind, start_ts, start_tz_offset_min, end_ts, end_tz_offset_min, source, imported_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """)
        defer { eventStmt.finalize() }

        let activityStmt = try database.prepare("""
            INSERT INTO activities
                (event_id, start_lat, start_lon, end_lat, end_lon, distance_m, mode, probability)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """)
        defer { activityStmt.finalize() }

        let visitStmt = try database.prepare("""
            INSERT INTO visits
                (event_id, place_id, lat, lon, semantic_type, hierarchy_level, probability)
            VALUES (?, ?, ?, ?, ?, ?, ?);
        """)
        defer { visitStmt.finalize() }

        let pathStmt = try database.prepare("""
            INSERT INTO path_points (event_id, seq, offset_min, lat, lon) VALUES (?, ?, ?, ?, ?);
        """)
        defer { pathStmt.finalize() }

        for event in slice {
            try bindAndStepEvent(event, stmt: eventStmt, importedAt: importedAt)
            // INSERT OR IGNORE skips an event whose id (deterministic across re-imports)
            // already exists; its children are already present, so don't re-insert them.
            guard eventStmt.changes > 0 else { continue }

            switch event.kind {
            case let .activity(details):
                try bindAndStepActivity(eventID: event.id, details: details, stmt: activityStmt)
            case let .visit(details):
                try bindAndStepVisit(eventID: event.id, details: details, stmt: visitStmt)
            case let .path(points):
                for (seq, point) in points.enumerated() {
                    try bindAndStepPathPoint(eventID: event.id, seq: seq, point: point, stmt: pathStmt)
                }
            }
        }
    }

    private func bindAndStepEvent(
        _ event: Event,
        stmt: PreparedStatement,
        importedAt: Int64
    ) throws {
        try stmt.reset()
        try stmt.bind(1, text: event.id.uuidString)
        try stmt.bind(2, text: event.kind.discriminator)
        try stmt.bind(3, int64: Int64(event.start.date.timeIntervalSince1970))
        try stmt.bind(4, int: event.start.tzOffsetMinutes)
        try stmt.bind(5, int64: Int64(event.end.date.timeIntervalSince1970))
        try stmt.bind(6, int: event.end.tzOffsetMinutes)
        try stmt.bind(7, text: event.source)
        try stmt.bind(8, int64: importedAt)
        try stmt.stepDone()
    }

    private func bindAndStepActivity(
        eventID: UUID,
        details: ActivityDetails,
        stmt: PreparedStatement
    ) throws {
        try stmt.reset()
        try stmt.bind(1, text: eventID.uuidString)
        try stmt.bind(2, double: details.start.latitude)
        try stmt.bind(3, double: details.start.longitude)
        try stmt.bind(4, double: details.end.latitude)
        try stmt.bind(5, double: details.end.longitude)
        try stmt.bind(6, double: details.distanceMeters)
        try stmt.bind(7, text: details.mode)
        try stmt.bind(8, double: details.probability)
        try stmt.stepDone()
    }

    private func bindAndStepVisit(
        eventID: UUID,
        details: VisitDetails,
        stmt: PreparedStatement
    ) throws {
        try stmt.reset()
        try stmt.bind(1, text: eventID.uuidString)
        try stmt.bind(2, text: details.placeID)
        try stmt.bind(3, double: details.location.latitude)
        try stmt.bind(4, double: details.location.longitude)
        try stmt.bind(5, text: details.semanticType)
        try stmt.bind(6, int: details.hierarchyLevel)
        try stmt.bind(7, double: details.probability)
        try stmt.stepDone()
    }

    private func bindAndStepPathPoint(
        eventID: UUID,
        seq: Int,
        point: PathPoint,
        stmt: PreparedStatement
    ) throws {
        try stmt.reset()
        try stmt.bind(1, text: eventID.uuidString)
        try stmt.bind(2, int: seq)
        try stmt.bind(3, int: point.offsetMinutes)
        try stmt.bind(4, double: point.coordinate.latitude)
        try stmt.bind(5, double: point.coordinate.longitude)
        try stmt.stepDone()
    }
}
