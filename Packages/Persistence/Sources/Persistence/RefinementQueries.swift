import Core
import Foundation

/// Audit row for a refined trip. Mirrors the `path_refinements` schema 1:1.
public struct RefinementRecord: Hashable, Sendable {
    public let eventID: UUID
    public let refinedAt: Date
    public let source: String
    public let routeName: String?
    public let transportType: String
    public let similarityMeanMeters: Double
    public let similarityP95Meters: Double
    public let similarityMaxMeters: Double
    public let expectedTravelTimeSeconds: Double?
    public let expectedDistanceMeters: Double?
    public let candidateCount: Int
    public let chosenIndex: Int
    public let originalPointCount: Int
    public let refinedPointCount: Int
    /// Nil for single-trip refinements; for a journey-level refinement, every original
    /// event id that was marked superseded so revert can restore them all.
    public let journeyMemberIDs: [UUID]?

    public init(
        eventID: UUID,
        refinedAt: Date,
        source: String,
        routeName: String?,
        transportType: String,
        similarityMeanMeters: Double,
        similarityP95Meters: Double,
        similarityMaxMeters: Double,
        expectedTravelTimeSeconds: Double?,
        expectedDistanceMeters: Double?,
        candidateCount: Int,
        chosenIndex: Int,
        originalPointCount: Int,
        refinedPointCount: Int,
        journeyMemberIDs: [UUID]? = nil
    ) {
        self.eventID = eventID
        self.refinedAt = refinedAt
        self.source = source
        self.routeName = routeName
        self.transportType = transportType
        self.similarityMeanMeters = similarityMeanMeters
        self.similarityP95Meters = similarityP95Meters
        self.similarityMaxMeters = similarityMaxMeters
        self.expectedTravelTimeSeconds = expectedTravelTimeSeconds
        self.expectedDistanceMeters = expectedDistanceMeters
        self.candidateCount = candidateCount
        self.chosenIndex = chosenIndex
        self.originalPointCount = originalPointCount
        self.refinedPointCount = refinedPointCount
        self.journeyMemberIDs = journeyMemberIDs
    }
}

/// Reasons a trip was checked but not refined. Persisted in `path_refinement_skips.reason`.
public enum SkipReason: String, Hashable, Sendable, CaseIterable {
    case noCandidates = "no_candidates"
    case tooShort = "too_short"
    case tooLong = "too_long"
    case userRejected = "user_rejected"
    case transitUnavailable = "transit_unavailable"
    case lowScore = "low_score"
}

/// One leg of a multi-modal refinement. Apply emits one `LegInput` per leg; the
/// queries layer creates a derived activity event for each.
public struct LegInput: Hashable, Sendable {
    public let mode: String
    public let label: String?
    public let coordinates: [Coordinate]
    public let distanceMeters: Double
    public let travelTimeSeconds: Double
    public let probability: Double

    public init(
        mode: String,
        label: String?,
        coordinates: [Coordinate],
        distanceMeters: Double,
        travelTimeSeconds: Double,
        probability: Double = 1.0
    ) {
        self.mode = mode
        self.label = label
        self.coordinates = coordinates
        self.distanceMeters = distanceMeters
        self.travelTimeSeconds = travelTimeSeconds
        self.probability = probability
    }
}

public extension Persistence {
    // MARK: - Apply / Revert

    /// Journey-level apply. Replaces every event id in `supersededEventIDs` (multiple
    /// originals — activities + short transit visits making up the journey) with N
    /// derived activities subdividing `[journeyStartTs, journeyEndTs]` proportionally to
    /// leg durations. Stores the member list on the audit row so revert can restore them.
    static func applyJourneyRefinement(
        in database: SQLCipherDatabase,
        primaryEventID: UUID,
        supersededEventIDs: [UUID],
        journeyStartTs: Int64,
        journeyEndTs: Int64,
        timezoneOffsetMin: Int,
        source: String,
        originalSamples: [Coordinate],
        legs: [LegInput],
        record: RefinementRecord
    ) throws {
        try database.transaction {
            // 1. Snapshot original GPS samples once (idempotent).
            try insertOriginalSnapshot(
                in: database,
                eventID: primaryEventID,
                samples: originalSamples
            )

            // 2. Supersede every original in the journey.
            try setSuperseded(
                in: database,
                eventIDs: supersededEventIDs,
                value: 1
            )

            // 3. Subdivide the journey time window proportionally to leg durations and
            //    insert derived activity events + their path_points.
            let totalLegSeconds = legs.reduce(0.0) { $0 + max($1.travelTimeSeconds, 1) }
            let totalDuration = journeyEndTs - journeyStartTs
            let parentInfo = ParentEventInfo(
                startTs: journeyStartTs,
                startTzOffsetMin: timezoneOffsetMin,
                endTs: journeyEndTs,
                endTzOffsetMin: timezoneOffsetMin,
                source: source
            )

            var cursor = journeyStartTs
            for (index, leg) in legs.enumerated() {
                let isLast = index == legs.count - 1
                let fraction = max(leg.travelTimeSeconds, 1) / totalLegSeconds
                let allocated = Int64((Double(totalDuration) * fraction).rounded())
                let legStart = cursor
                let legEnd = isLast ? journeyEndTs : (legStart + allocated)
                cursor = legEnd

                let derivedID = UUID()
                let start = leg.coordinates.first ?? Coordinate(latitude: 0, longitude: 0)
                let end = leg.coordinates.last ?? start

                try insertDerivedEvent(
                    in: database,
                    derivedID: derivedID,
                    parent: parentInfo,
                    parentEventID: primaryEventID,
                    startTs: legStart,
                    endTs: legEnd
                )
                try insertDerivedActivity(
                    in: database,
                    eventID: derivedID,
                    leg: leg,
                    start: start,
                    end: end
                )
                try insertPathPoints(
                    in: database,
                    eventID: derivedID,
                    coordinates: leg.coordinates
                )
            }

            // 4. Audit row carries the member list so revert is precise.
            try upsertRefinementRecord(in: database, record: record)

            // 5. Clear any prior skip flag on the primary.
            let skipDel = try database.prepare("DELETE FROM path_refinement_skips WHERE event_id = ?;")
            defer { skipDel.finalize() }
            try skipDel.bind(1, text: primaryEventID.uuidString)
            try skipDel.stepDone()
        }
    }

    /// Multi-leg apply for a single activity (legacy single-row entry point). Creates one
    /// derived `activity` event per leg, links each to the original via
    /// `derived_from_event_id`, populates `path_points` for each derived event, and marks
    /// the original superseded. Writes a single audit row keyed to the original.
    static func applyMultiLegRefinement(
        in database: SQLCipherDatabase,
        originalEventID: UUID,
        originalSamples: [Coordinate],
        legs: [LegInput],
        record: RefinementRecord
    ) throws {
        try database.transaction {
            // 1. Snapshot the original GPS samples once (idempotent).
            try insertOriginalSnapshot(
                in: database,
                eventID: originalEventID,
                samples: originalSamples
            )

            // 2. Mark the original as superseded so timeline/map queries hide it.
            let supersedeStmt = try database.prepare("UPDATE events SET is_superseded = 1 WHERE id = ?;")
            defer { supersedeStmt.finalize() }
            try supersedeStmt.bind(1, text: originalEventID.uuidString)
            try supersedeStmt.stepDone()

            // 3. Read the original's time window + source so we can subdivide it.
            let parent = try fetchEventTimeWindow(in: database, eventID: originalEventID)
            guard let parent else { return }
            let totalLegSeconds = legs.reduce(0.0) { $0 + max($1.travelTimeSeconds, 1) }
            let parentDuration = parent.endTs - parent.startTs

            var cursor = parent.startTs
            for (index, leg) in legs.enumerated() {
                let isLast = index == legs.count - 1
                let fraction = max(leg.travelTimeSeconds, 1) / totalLegSeconds
                let allocated = Int64((Double(parentDuration) * fraction).rounded())
                let legStart = cursor
                let legEnd = isLast ? parent.endTs : (legStart + allocated)
                cursor = legEnd

                let derivedID = UUID()
                let start = leg.coordinates.first ?? Coordinate(latitude: 0, longitude: 0)
                let end = leg.coordinates.last ?? start

                try insertDerivedEvent(
                    in: database,
                    derivedID: derivedID,
                    parent: parent,
                    parentEventID: originalEventID,
                    startTs: legStart,
                    endTs: legEnd
                )
                try insertDerivedActivity(
                    in: database,
                    eventID: derivedID,
                    leg: leg,
                    start: start,
                    end: end
                )
                try insertPathPoints(
                    in: database,
                    eventID: derivedID,
                    coordinates: leg.coordinates
                )
            }

            // 4. Single audit row keyed to the original event id.
            try upsertRefinementRecord(in: database, record: record)

            // 5. Clear any prior skip flag.
            let skipDel = try database.prepare("DELETE FROM path_refinement_skips WHERE event_id = ?;")
            defer { skipDel.finalize() }
            try skipDel.bind(1, text: originalEventID.uuidString)
            try skipDel.stepDone()
        }
    }

    /// Replaces `path_points` for `eventID` with `refinedPoints`. The first apply for an
    /// event snapshots the existing samples into `path_points_original` so revert is possible.
    /// Subsequent applies keep that original snapshot untouched (INSERT OR IGNORE).
    static func applyRefinement(
        in database: SQLCipherDatabase,
        eventID: UUID,
        originalSamples: [Coordinate],
        refinedPoints: [Coordinate],
        record: RefinementRecord
    ) throws {
        try database.transaction {
            // 1. Snapshot the original GPS samples (idempotent — first apply wins).
            try insertOriginalSnapshot(
                in: database,
                eventID: eventID,
                samples: originalSamples
            )

            // 2. Wipe existing path_points for the event and write the refined polyline.
            let deleteStmt = try database.prepare("DELETE FROM path_points WHERE event_id = ?;")
            defer { deleteStmt.finalize() }
            try deleteStmt.bind(1, text: eventID.uuidString)
            try deleteStmt.stepDone()
            try insertPathPoints(in: database, eventID: eventID, coordinates: refinedPoints)

            // 3. Single-leg refinement does not supersede the activity (no derived events
            //    take its place) — the activity row stays visible with its new polyline.
            let unsupersede = try database.prepare("UPDATE events SET is_superseded = 0 WHERE id = ?;")
            defer { unsupersede.finalize() }
            try unsupersede.bind(1, text: eventID.uuidString)
            try unsupersede.stepDone()

            // 4. Upsert audit row.
            try upsertRefinementRecord(in: database, record: record)

            // 5. Drop any prior skip row.
            let skipDelStmt = try database.prepare("DELETE FROM path_refinement_skips WHERE event_id = ?;")
            defer { skipDelStmt.finalize() }
            try skipDelStmt.bind(1, text: eventID.uuidString)
            try skipDelStmt.stepDone()
        }
    }

    // MARK: - Internals shared by single- and multi-leg apply

    private static func insertOriginalSnapshot(
        in database: SQLCipherDatabase,
        eventID: UUID,
        samples: [Coordinate]
    ) throws {
        // Skip if a snapshot already exists — first apply wins.
        let checkStmt = try database.prepare("SELECT 1 FROM path_points_original WHERE event_id = ? LIMIT 1;")
        defer { checkStmt.finalize() }
        try checkStmt.bind(1, text: eventID.uuidString)
        if try checkStmt.step() == .row { return }

        let insertStmt = try database.prepare("""
            INSERT INTO path_points_original (event_id, seq, offset_min, lat, lon)
            VALUES (?, ?, ?, ?, ?);
        """)
        defer { insertStmt.finalize() }
        for (seq, sample) in samples.enumerated() {
            try insertStmt.reset()
            try insertStmt.bind(1, text: eventID.uuidString)
            try insertStmt.bind(2, int: seq)
            try insertStmt.bind(3, int: 0)
            try insertStmt.bind(4, double: sample.latitude)
            try insertStmt.bind(5, double: sample.longitude)
            try insertStmt.stepDone()
        }
    }

    private static func insertPathPoints(
        in database: SQLCipherDatabase,
        eventID: UUID,
        coordinates: [Coordinate]
    ) throws {
        let insertStmt = try database.prepare("""
            INSERT INTO path_points (event_id, seq, offset_min, lat, lon)
            VALUES (?, ?, ?, ?, ?);
        """)
        defer { insertStmt.finalize() }
        for (seq, point) in coordinates.enumerated() {
            try insertStmt.reset()
            try insertStmt.bind(1, text: eventID.uuidString)
            try insertStmt.bind(2, int: seq)
            try insertStmt.bind(3, int: 0)
            try insertStmt.bind(4, double: point.latitude)
            try insertStmt.bind(5, double: point.longitude)
            try insertStmt.stepDone()
        }
    }

    struct ParentEventInfo {
        let startTs: Int64
        let startTzOffsetMin: Int
        let endTs: Int64
        let endTzOffsetMin: Int
        let source: String
    }

    private static func fetchEventTimeWindow(
        in database: SQLCipherDatabase,
        eventID: UUID
    ) throws -> ParentEventInfo? {
        let stmt = try database.prepare("""
            SELECT start_ts, start_tz_offset_min, end_ts, end_tz_offset_min, source
            FROM events WHERE id = ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: eventID.uuidString)
        guard try stmt.step() == .row else { return nil }
        return ParentEventInfo(
            startTs: stmt.columnInt64(0),
            startTzOffsetMin: stmt.columnInt(1),
            endTs: stmt.columnInt64(2),
            endTzOffsetMin: stmt.columnInt(3),
            source: stmt.columnText(4) ?? "refinement"
        )
    }

    private static func insertDerivedEvent(
        in database: SQLCipherDatabase,
        derivedID: UUID,
        parent: ParentEventInfo,
        parentEventID: UUID,
        startTs: Int64,
        endTs: Int64
    ) throws {
        let stmt = try database.prepare("""
            INSERT INTO events (
                id, kind, start_ts, start_tz_offset_min,
                end_ts, end_tz_offset_min, source, imported_at,
                derived_from_event_id, is_superseded
            ) VALUES (?, 'activity', ?, ?, ?, ?, ?, ?, ?, 0);
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: derivedID.uuidString)
        try stmt.bind(2, int64: startTs)
        try stmt.bind(3, int: parent.startTzOffsetMin)
        try stmt.bind(4, int64: endTs)
        try stmt.bind(5, int: parent.endTzOffsetMin)
        try stmt.bind(6, text: parent.source)
        try stmt.bind(7, int64: Int64(Date().timeIntervalSince1970))
        try stmt.bind(8, text: parentEventID.uuidString)
        try stmt.stepDone()
    }

    private static func insertDerivedActivity(
        in database: SQLCipherDatabase,
        eventID: UUID,
        leg: LegInput,
        start: Coordinate,
        end: Coordinate
    ) throws {
        let stmt = try database.prepare("""
            INSERT INTO activities (event_id, start_lat, start_lon, end_lat, end_lon, distance_m, mode, probability)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: eventID.uuidString)
        try stmt.bind(2, double: start.latitude)
        try stmt.bind(3, double: start.longitude)
        try stmt.bind(4, double: end.latitude)
        try stmt.bind(5, double: end.longitude)
        try stmt.bind(6, double: leg.distanceMeters)
        // Mode column stores the granular mode string ("bus", "train", "subway", etc.) so
        // TripStyle picks the right icon + label. The leg's optional `label` (line name) is
        // ignored for now — user wants the bare mode word, not "Bus 38" or "Commuter train A".
        try stmt.bind(7, text: leg.mode)
        try stmt.bind(8, double: leg.probability)
        try stmt.stepDone()
    }

    private static func upsertRefinementRecord(
        in database: SQLCipherDatabase,
        record: RefinementRecord
    ) throws {
        let stmt = try database.prepare("""
            INSERT INTO path_refinements (
                event_id, refined_at, source, route_name, transport_type,
                similarity_mean_m, similarity_p95_m, similarity_max_m,
                expected_travel_s, expected_distance_m,
                candidate_count, chosen_index, original_point_count, refined_point_count,
                journey_member_ids
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(event_id) DO UPDATE SET
                refined_at           = excluded.refined_at,
                source               = excluded.source,
                route_name           = excluded.route_name,
                transport_type       = excluded.transport_type,
                similarity_mean_m    = excluded.similarity_mean_m,
                similarity_p95_m     = excluded.similarity_p95_m,
                similarity_max_m     = excluded.similarity_max_m,
                expected_travel_s    = excluded.expected_travel_s,
                expected_distance_m  = excluded.expected_distance_m,
                candidate_count      = excluded.candidate_count,
                chosen_index         = excluded.chosen_index,
                original_point_count = excluded.original_point_count,
                refined_point_count  = excluded.refined_point_count,
                journey_member_ids   = excluded.journey_member_ids;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: record.eventID.uuidString)
        try stmt.bind(2, int64: Int64(record.refinedAt.timeIntervalSince1970))
        try stmt.bind(3, text: record.source)
        if let name = record.routeName { try stmt.bind(4, text: name) } else { try stmt.bindNull(4) }
        try stmt.bind(5, text: record.transportType)
        try stmt.bind(6, double: record.similarityMeanMeters)
        try stmt.bind(7, double: record.similarityP95Meters)
        try stmt.bind(8, double: record.similarityMaxMeters)
        if let t = record.expectedTravelTimeSeconds { try stmt.bind(9, double: t) } else { try stmt.bindNull(9) }
        if let d = record.expectedDistanceMeters { try stmt.bind(10, double: d) } else { try stmt.bindNull(10) }
        try stmt.bind(11, int: record.candidateCount)
        try stmt.bind(12, int: record.chosenIndex)
        try stmt.bind(13, int: record.originalPointCount)
        try stmt.bind(14, int: record.refinedPointCount)
        if let ids = record.journeyMemberIDs, !ids.isEmpty {
            try stmt.bind(15, text: ids.map(\.uuidString).joined(separator: ","))
        } else {
            try stmt.bindNull(15)
        }
        try stmt.stepDone()
    }

    /// Reverts a refinement back to the recorded state. Handles single-leg, multi-leg,
    /// and journey-level cases:
    ///   - Always: drop derived events keyed to this primary, clear path_points keyed to
    ///     this event id, drop snapshot + audit row.
    ///   - Journey: un-supersede every id in the audit row's `journey_member_ids`.
    ///   - Otherwise: un-supersede just `eventID`.
    static func revertRefinement(in database: SQLCipherDatabase, eventID: UUID) throws {
        // Read the audit row first so we know which ids (if any) belong to the journey.
        let memberIDs = (try refinement(in: database, eventID: eventID))?.journeyMemberIDs

        try database.transaction {
            // Wipe path_points keyed to the original activity (single-leg case may have
            // written some). CASCADE clears derived events' path_points when we delete
            // them next.
            let deleteCurrent = try database.prepare("DELETE FROM path_points WHERE event_id = ?;")
            defer { deleteCurrent.finalize() }
            try deleteCurrent.bind(1, text: eventID.uuidString)
            try deleteCurrent.stepDone()

            // Delete derived activity events (multi-leg / journey). CASCADE clears their
            // associated activities + path_points rows.
            let deleteDerived = try database.prepare("DELETE FROM events WHERE derived_from_event_id = ?;")
            defer { deleteDerived.finalize() }
            try deleteDerived.bind(1, text: eventID.uuidString)
            try deleteDerived.stepDone()

            // Un-supersede the right set of originals.
            if let ids = memberIDs, !ids.isEmpty {
                try setSuperseded(in: database, eventIDs: ids, value: 0)
            } else {
                let unsupersede = try database.prepare("UPDATE events SET is_superseded = 0 WHERE id = ?;")
                defer { unsupersede.finalize() }
                try unsupersede.bind(1, text: eventID.uuidString)
                try unsupersede.stepDone()
            }

            // Drop the snapshot — original samples for activities live in sibling path
            // events, which we never touch during apply.
            let deleteSnapshot = try database.prepare("DELETE FROM path_points_original WHERE event_id = ?;")
            defer { deleteSnapshot.finalize() }
            try deleteSnapshot.bind(1, text: eventID.uuidString)
            try deleteSnapshot.stepDone()

            // Drop the audit row.
            let deleteRefinement = try database.prepare("DELETE FROM path_refinements WHERE event_id = ?;")
            defer { deleteRefinement.finalize() }
            try deleteRefinement.bind(1, text: eventID.uuidString)
            try deleteRefinement.stepDone()
        }
    }

    /// Helper: set `is_superseded` for a list of event ids in one statement.
    private static func setSuperseded(
        in database: SQLCipherDatabase,
        eventIDs: [UUID],
        value: Int
    ) throws {
        guard !eventIDs.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: eventIDs.count).joined(separator: ", ")
        let stmt = try database.prepare(
            "UPDATE events SET is_superseded = ? WHERE id IN (\(placeholders));"
        )
        defer { stmt.finalize() }
        try stmt.bind(1, int: value)
        for (index, id) in eventIDs.enumerated() {
            try stmt.bind(Int32(index + 2), text: id.uuidString)
        }
        try stmt.stepDone()
    }

    // MARK: - Read

    /// Every activity event id in `dayRange` that has been refined — either has a
    /// `path_refinements` audit row (single-trip refinement) OR is a derived sub-activity
    /// from a multi-leg / journey-level refinement. Used by the timeline UI to badge
    /// refined rows so the user can tell them apart from raw recorded trips at a glance.
    static func fetchRefinedActivityIDs(
        in database: SQLCipherDatabase,
        dayRange: Range<Date>
    ) throws -> Set<UUID> {
        let start = Int64(dayRange.lowerBound.timeIntervalSince1970)
        let end = Int64(dayRange.upperBound.timeIntervalSince1970)
        let stmt = try database.prepare("""
            SELECT pr.event_id
            FROM path_refinements pr
            JOIN events e ON e.id = pr.event_id
            WHERE e.start_ts < ? AND (e.end_ts > ? OR e.start_ts >= ?)
            UNION
            SELECT id
            FROM events
            WHERE kind = 'activity'
              AND derived_from_event_id IS NOT NULL
              AND start_ts < ? AND (end_ts > ? OR start_ts >= ?);
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, int64: end)
        try stmt.bind(2, int64: start)
        try stmt.bind(3, int64: start)
        try stmt.bind(4, int64: end)
        try stmt.bind(5, int64: start)
        try stmt.bind(6, int64: start)
        var result: Set<UUID> = []
        while try stmt.step() == .row {
            if let text = stmt.columnText(0), let id = UUID(uuidString: text) {
                result.insert(id)
            }
        }
        return result
    }

    /// Returns activity-keyed path_points for every activity event in the day range that
    /// has rows in `path_points`. Multi-leg refinement creates these rows on derived
    /// activities; single-leg refinement creates them on the original. Used by the map
    /// renderer to draw refined polylines instead of the time-sliced GPS samples.
    static func fetchActivityPolylines(
        in database: SQLCipherDatabase,
        dayRange: Range<Date>
    ) throws -> [UUID: [Coordinate]] {
        let start = Int64(dayRange.lowerBound.timeIntervalSince1970)
        let end = Int64(dayRange.upperBound.timeIntervalSince1970)
        let stmt = try database.prepare("""
            SELECT pp.event_id, pp.lat, pp.lon, pp.seq
            FROM path_points pp
            JOIN events e ON e.id = pp.event_id
            WHERE e.kind = 'activity'
              AND e.is_superseded = 0
              AND e.start_ts < ? AND (e.end_ts > ? OR e.start_ts >= ?)
            ORDER BY pp.event_id, pp.seq;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, int64: end)
        try stmt.bind(2, int64: start)
        try stmt.bind(3, int64: start)
        var result: [UUID: [Coordinate]] = [:]
        while try stmt.step() == .row {
            guard let idText = stmt.columnText(0), let id = UUID(uuidString: idText) else { continue }
            let coord = Coordinate(latitude: stmt.columnDouble(1), longitude: stmt.columnDouble(2))
            result[id, default: []].append(coord)
        }
        return result
    }

    /// Returns the event id of the parent activity if `eventID` is a derived sub-activity
    /// (multi-leg refinement output), else nil. Used by the detail screen to surface
    /// "this is part of a refined journey — revert the whole journey" actions.
    static func parentEventID(in database: SQLCipherDatabase, eventID: UUID) throws -> UUID? {
        let stmt = try database.prepare("SELECT derived_from_event_id FROM events WHERE id = ?;")
        defer { stmt.finalize() }
        try stmt.bind(1, text: eventID.uuidString)
        guard try stmt.step() == .row, let text = stmt.columnText(0) else { return nil }
        return UUID(uuidString: text)
    }

    static func refinement(in database: SQLCipherDatabase, eventID: UUID) throws -> RefinementRecord? {
        let stmt = try database.prepare("""
            SELECT
                event_id, refined_at, source, route_name, transport_type,
                similarity_mean_m, similarity_p95_m, similarity_max_m,
                expected_travel_s, expected_distance_m,
                candidate_count, chosen_index, original_point_count, refined_point_count,
                journey_member_ids
            FROM path_refinements
            WHERE event_id = ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: eventID.uuidString)
        guard try stmt.step() == .row else { return nil }
        return makeRecord(from: stmt)
    }

    // MARK: - Skips

    static func markSkipped(
        in database: SQLCipherDatabase,
        eventID: UUID,
        reason: SkipReason,
        checkedAt: Date = Date()
    ) throws {
        let stmt = try database.prepare("""
            INSERT INTO path_refinement_skips (event_id, checked_at, reason)
            VALUES (?, ?, ?)
            ON CONFLICT(event_id) DO UPDATE SET
                checked_at = excluded.checked_at,
                reason     = excluded.reason;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: eventID.uuidString)
        try stmt.bind(2, int64: Int64(checkedAt.timeIntervalSince1970))
        try stmt.bind(3, text: reason.rawValue)
        try stmt.stepDone()
    }

    static func isSkipped(in database: SQLCipherDatabase, eventID: UUID) throws -> Bool {
        let stmt = try database.prepare("SELECT 1 FROM path_refinement_skips WHERE event_id = ? LIMIT 1;")
        defer { stmt.finalize() }
        try stmt.bind(1, text: eventID.uuidString)
        return try stmt.step() == .row
    }

    static func skipReason(in database: SQLCipherDatabase, eventID: UUID) throws -> SkipReason? {
        let stmt = try database.prepare("SELECT reason FROM path_refinement_skips WHERE event_id = ?;")
        defer { stmt.finalize() }
        try stmt.bind(1, text: eventID.uuidString)
        guard try stmt.step() == .row, let raw = stmt.columnText(0) else { return nil }
        return SkipReason(rawValue: raw)
    }

    // MARK: - Internals

    private static func makeRecord(from stmt: PreparedStatement) -> RefinementRecord? {
        guard let idText = stmt.columnText(0), let id = UUID(uuidString: idText) else { return nil }
        // expected_travel_s / expected_distance_m are nullable: a NULL column means "no value",
        // so read it back as nil rather than the 0.0 that columnDouble returns for NULL.
        let travel = stmt.columnIsNull(8) ? nil : stmt.columnDouble(8)
        let distance = stmt.columnIsNull(9) ? nil : stmt.columnDouble(9)
        let memberIDs: [UUID]? = stmt.columnText(14).flatMap { raw in
            let parts = raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            return parts.isEmpty ? nil : parts
        }
        return RefinementRecord(
            eventID: id,
            refinedAt: Date(timeIntervalSince1970: TimeInterval(stmt.columnInt64(1))),
            source: stmt.columnText(2) ?? "",
            routeName: stmt.columnText(3),
            transportType: stmt.columnText(4) ?? "",
            similarityMeanMeters: stmt.columnDouble(5),
            similarityP95Meters: stmt.columnDouble(6),
            similarityMaxMeters: stmt.columnDouble(7),
            expectedTravelTimeSeconds: travel,
            expectedDistanceMeters: distance,
            candidateCount: stmt.columnInt(10),
            chosenIndex: stmt.columnInt(11),
            originalPointCount: stmt.columnInt(12),
            refinedPointCount: stmt.columnInt(13),
            journeyMemberIDs: memberIDs
        )
    }
}
