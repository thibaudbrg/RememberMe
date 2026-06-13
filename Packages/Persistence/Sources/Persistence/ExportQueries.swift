import Core
import Foundation

public extension Persistence {
    /// Dumps the entire database into an `ExportPayload`. Heavy — loads every event into
    /// memory. Acceptable here because the export is a one-shot user action; the resulting
    /// JSON is what's heavy, not the in-memory representation.
    static func fetchExportPayload(in database: SQLCipherDatabase, exportedAt: Date = Date()) throws -> ExportPayload {
        let events = try fetchExportedEvents(in: database)
        let places = try fetchExportedPlaces(in: database)
        return ExportPayload(
            version: 2,
            exportedAt: exportedAt,
            events: events,
            places: places
        )
    }

    /// Restores an `ExportPayload` additively. Inserts use `OR IGNORE` on the primary key,
    /// so re-importing the same file (or merging multiple backups) won't create duplicates.
    /// Returns the number of *new* event rows that landed.
    @discardableResult
    static func restore(
        payload: ExportPayload,
        in database: SQLCipherDatabase,
        importedAt: Date = Date()
    ) throws -> Int {
        let importedAtUnix = Int64(importedAt.timeIntervalSince1970)
        var newEventCount = 0

        try database.transaction {
            let eventStmt = try database.prepare("""
                INSERT OR IGNORE INTO events
                    (id, kind, start_ts, start_tz_offset_min, end_ts, end_tz_offset_min, source, imported_at,
                     is_superseded, derived_from_event_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { eventStmt.finalize() }

            let activityStmt = try database.prepare("""
                INSERT OR IGNORE INTO activities
                    (event_id, start_lat, start_lon, end_lat, end_lon, distance_m, mode, probability)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { activityStmt.finalize() }

            let visitStmt = try database.prepare("""
                INSERT OR IGNORE INTO visits
                    (event_id, place_id, lat, lon, semantic_type, hierarchy_level, probability)
                VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
            defer { visitStmt.finalize() }

            let pathStmt = try database.prepare("""
                INSERT OR IGNORE INTO path_points (event_id, seq, offset_min, lat, lon)
                VALUES (?, ?, ?, ?, ?);
            """)
            defer { pathStmt.finalize() }

            let changesStmt = try database.prepare("SELECT changes();")
            defer { changesStmt.finalize() }

            for event in payload.events {
                try eventStmt.reset()
                try eventStmt.bind(1, text: event.id)
                try eventStmt.bind(2, text: event.kind)
                try eventStmt.bind(3, int64: event.startTs)
                try eventStmt.bind(4, int: event.startTzOffsetMin)
                try eventStmt.bind(5, int64: event.endTs)
                try eventStmt.bind(6, int: event.endTzOffsetMin)
                try eventStmt.bind(7, text: event.source)
                // Use the original imported_at if non-zero, else stamp with now — keeps
                // provenance when re-importing the same backup.
                try eventStmt.bind(8, int64: event.importedAt > 0 ? event.importedAt : importedAtUnix)
                try eventStmt.bind(9, int: event.isSuperseded ? 1 : 0)
                if let derivedFrom = event.derivedFromEventID {
                    try eventStmt.bind(10, text: derivedFrom)
                } else {
                    try eventStmt.bindNull(10)
                }
                try eventStmt.stepDone()

                // changes() returns row count from the last INSERT — 0 means the OR IGNORE
                // skipped because of a primary-key conflict.
                try changesStmt.reset()
                if try changesStmt.step() == .row, changesStmt.columnInt(0) > 0 {
                    newEventCount += 1
                }

                if let activity = event.activity {
                    try activityStmt.reset()
                    try activityStmt.bind(1, text: event.id)
                    try activityStmt.bind(2, double: activity.startLat)
                    try activityStmt.bind(3, double: activity.startLon)
                    try activityStmt.bind(4, double: activity.endLat)
                    try activityStmt.bind(5, double: activity.endLon)
                    try activityStmt.bind(6, double: activity.distanceM)
                    try activityStmt.bind(7, text: activity.mode)
                    try activityStmt.bind(8, double: activity.probability)
                    try activityStmt.stepDone()
                }
                if let visit = event.visit {
                    try visitStmt.reset()
                    try visitStmt.bind(1, text: event.id)
                    try visitStmt.bind(2, text: visit.placeID)
                    try visitStmt.bind(3, double: visit.lat)
                    try visitStmt.bind(4, double: visit.lon)
                    try visitStmt.bind(5, text: visit.semanticType)
                    try visitStmt.bind(6, int: visit.hierarchyLevel)
                    try visitStmt.bind(7, double: visit.probability)
                    try visitStmt.stepDone()
                }
                if let points = event.pathPoints {
                    for point in points {
                        try pathStmt.reset()
                        try pathStmt.bind(1, text: event.id)
                        try pathStmt.bind(2, int: point.seq)
                        try pathStmt.bind(3, int: point.offsetMin)
                        try pathStmt.bind(4, double: point.lat)
                        try pathStmt.bind(5, double: point.lon)
                        try pathStmt.stepDone()
                    }
                }
            }

            // Places: upsert so a backup with a curated user_label wins over a default-only
            // row already in the DB. Same conflict-resolution rules as upsertPlace().
            let placeStmt = try database.prepare("""
                INSERT INTO places (place_id, user_label, resolved_label, resolved_at, lat, lon)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(place_id) DO UPDATE SET
                    user_label     = COALESCE(excluded.user_label, places.user_label),
                    resolved_label = COALESCE(excluded.resolved_label, places.resolved_label),
                    resolved_at    = MAX(COALESCE(excluded.resolved_at, 0), COALESCE(places.resolved_at, 0)),
                    lat            = excluded.lat,
                    lon            = excluded.lon;
            """)
            defer { placeStmt.finalize() }

            for place in payload.places {
                try placeStmt.reset()
                try placeStmt.bind(1, text: place.placeID)
                if let label = place.userLabel { try placeStmt.bind(2, text: label) } else { try placeStmt.bindNull(2) }
                if let label = place.resolvedLabel { try placeStmt.bind(3, text: label) } else { try placeStmt.bindNull(3) }
                try placeStmt.bind(4, int64: place.resolvedAt ?? 0)
                try placeStmt.bind(5, double: place.lat)
                try placeStmt.bind(6, double: place.lon)
                try placeStmt.stepDone()
            }
        }

        return newEventCount
    }

    // MARK: - Internals

    private static func fetchExportedEvents(in database: SQLCipherDatabase) throws -> [ExportedEvent] {
        let stmt = try database.prepare("""
            SELECT
                e.id, e.kind, e.start_ts, e.start_tz_offset_min,
                e.end_ts, e.end_tz_offset_min, e.source, e.imported_at,
                a.start_lat, a.start_lon, a.end_lat, a.end_lon,
                a.distance_m, a.mode, a.probability,
                v.place_id, v.lat, v.lon, v.semantic_type, v.hierarchy_level, v.probability,
                e.is_superseded, e.derived_from_event_id
            FROM events e
            LEFT JOIN activities a ON a.event_id = e.id
            LEFT JOIN visits     v ON v.event_id = e.id
            ORDER BY e.start_ts ASC;
        """)
        defer { stmt.finalize() }

        var events: [ExportedEvent] = []
        while try stmt.step() == .row {
            guard let id = stmt.columnText(0),
                  let kind = stmt.columnText(1)
            else { continue }

            var activity: ExportedActivity?
            var visit: ExportedVisit?
            if kind == "activity", let mode = stmt.columnText(13) {
                activity = ExportedActivity(
                    startLat: stmt.columnDouble(8),
                    startLon: stmt.columnDouble(9),
                    endLat: stmt.columnDouble(10),
                    endLon: stmt.columnDouble(11),
                    distanceM: stmt.columnDouble(12),
                    mode: mode,
                    probability: stmt.columnDouble(14)
                )
            } else if kind == "visit", let placeID = stmt.columnText(15) {
                visit = ExportedVisit(
                    placeID: placeID,
                    lat: stmt.columnDouble(16),
                    lon: stmt.columnDouble(17),
                    semanticType: stmt.columnText(18) ?? "Unknown",
                    hierarchyLevel: stmt.columnInt(19),
                    probability: stmt.columnDouble(20)
                )
            }

            events.append(ExportedEvent(
                id: id,
                kind: kind,
                startTs: stmt.columnInt64(2),
                startTzOffsetMin: stmt.columnInt(3),
                endTs: stmt.columnInt64(4),
                endTzOffsetMin: stmt.columnInt(5),
                source: stmt.columnText(6) ?? "",
                importedAt: stmt.columnInt64(7),
                isSuperseded: stmt.columnInt(21) != 0,
                derivedFromEventID: stmt.columnText(22),
                activity: activity,
                visit: visit,
                pathPoints: nil
            ))
        }

        // Second pass: path_points. Done after the events scan so we don't multiply rows.
        let pathStmt = try database.prepare("""
            SELECT event_id, seq, offset_min, lat, lon
            FROM path_points
            ORDER BY event_id, seq ASC;
        """)
        defer { pathStmt.finalize() }

        var pointsByEvent: [String: [ExportedPathPoint]] = [:]
        while try pathStmt.step() == .row {
            guard let eventID = pathStmt.columnText(0) else { continue }
            pointsByEvent[eventID, default: []].append(ExportedPathPoint(
                seq: pathStmt.columnInt(1),
                offsetMin: pathStmt.columnInt(2),
                lat: pathStmt.columnDouble(3),
                lon: pathStmt.columnDouble(4)
            ))
        }
        // Attach points to their parent path events.
        return events.map { event in
            guard event.kind == "path", let points = pointsByEvent[event.id] else { return event }
            return ExportedEvent(
                id: event.id,
                kind: event.kind,
                startTs: event.startTs,
                startTzOffsetMin: event.startTzOffsetMin,
                endTs: event.endTs,
                endTzOffsetMin: event.endTzOffsetMin,
                source: event.source,
                importedAt: event.importedAt,
                isSuperseded: event.isSuperseded,
                derivedFromEventID: event.derivedFromEventID,
                activity: event.activity,
                visit: event.visit,
                pathPoints: points
            )
        }
    }

    private static func fetchExportedPlaces(in database: SQLCipherDatabase) throws -> [ExportedPlace] {
        let stmt = try database.prepare("""
            SELECT place_id, user_label, resolved_label, resolved_at, lat, lon
            FROM places
            ORDER BY place_id ASC;
        """)
        defer { stmt.finalize() }

        var places: [ExportedPlace] = []
        while try stmt.step() == .row {
            guard let placeID = stmt.columnText(0) else { continue }
            let resolvedAt = stmt.columnInt64(3)
            places.append(ExportedPlace(
                placeID: placeID,
                userLabel: stmt.columnText(1),
                resolvedLabel: stmt.columnText(2),
                resolvedAt: resolvedAt > 0 ? resolvedAt : nil,
                lat: stmt.columnDouble(4),
                lon: stmt.columnDouble(5)
            ))
        }
        return places
    }
}
