import Core
import XCTest
@testable import Persistence

final class RefinementQueriesTests: XCTestCase {
    private var database: SQLCipherDatabase!

    override func setUpWithError() throws {
        database = try DatabaseFactory.open(
            at: SQLCipherDatabase.inMemoryPath,
            keyStore: InMemoryKeyStore(),
            excludeFromBackup: false
        )
    }

    override func tearDown() {
        database = nil
    }

    func testMigrationAppliesV2Tables() throws {
        // Schema v2 should have created the three new tables on open.
        for table in ["path_points_original", "path_refinements", "path_refinement_skips"] {
            let stmt = try database.prepare("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?;")
            defer { stmt.finalize() }
            try stmt.bind(1, text: table)
            XCTAssertEqual(stmt.step(), .row)
            XCTAssertEqual(stmt.columnInt(0), 1, "expected \(table) to exist")
        }
        XCTAssertEqual(try database.userVersion(), Schema.currentVersion)
    }

    func testMigrationIsIdempotent() throws {
        // Apply again — should be a no-op (user_version already at 2).
        try Migrations.apply(to: database)
        XCTAssertEqual(try database.userVersion(), Schema.currentVersion)
    }

    func testApplyAndReadRoundTrip() throws {
        let eventID = try seedTripWithPath(points: originalPoints)

        let refined = [
            Coordinate(latitude: 48.8580, longitude: 2.3540),
            Coordinate(latitude: 48.8590, longitude: 2.3550),
            Coordinate(latitude: 48.8600, longitude: 2.3560),
        ]
        let record = makeRecord(eventID: eventID, refinedCount: refined.count)
        try Persistence.applyRefinement(
            in: database,
            eventID: eventID,
            originalSamples: originalPoints,
            refinedPoints: refined,
            record: record
        )

        // path_points now contains the refined polyline.
        let points = try Persistence.fetchPathPoints(in: database, eventID: eventID)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].latitude, 48.8580, accuracy: 1e-6)

        // Audit row read back.
        let read = try XCTUnwrap(Persistence.refinement(in: database, eventID: eventID))
        XCTAssertEqual(read.eventID, eventID)
        XCTAssertEqual(read.transportType, "walking")
        XCTAssertEqual(read.refinedPointCount, 3)
    }

    func testReapplyKeepsOriginalSnapshot() throws {
        let eventID = try seedTripWithPath(points: originalPoints)

        let refinedA = [
            Coordinate(latitude: 48.8580, longitude: 2.3540),
            Coordinate(latitude: 48.8590, longitude: 2.3550),
        ]
        try Persistence.applyRefinement(
            in: database,
            eventID: eventID,
            originalSamples: originalPoints,
            refinedPoints: refinedA,
            record: makeRecord(eventID: eventID, refinedCount: refinedA.count)
        )

        // The snapshot stored the original 4 points.
        XCTAssertEqual(try originalCount(eventID: eventID), originalPoints.count)

        // Apply again — snapshot must NOT be overwritten with refinedA.
        let refinedB = [
            Coordinate(latitude: 48.8585, longitude: 2.3545),
        ]
        try Persistence.applyRefinement(
            in: database,
            eventID: eventID,
            originalSamples: originalPoints,
            refinedPoints: refinedB,
            record: makeRecord(eventID: eventID, refinedCount: refinedB.count)
        )
        XCTAssertEqual(try originalCount(eventID: eventID), originalPoints.count)

        // Current path is the latest refined polyline.
        XCTAssertEqual(try Persistence.fetchPathPoints(in: database, eventID: eventID).count, 1)
    }

    func testRevertRestoresOriginalsAndRemovesAuditAndSnapshot() throws {
        let eventID = try seedTripWithPath(points: originalPoints)
        let refined = [
            Coordinate(latitude: 48.8580, longitude: 2.3540),
            Coordinate(latitude: 48.8590, longitude: 2.3550),
        ]
        try Persistence.applyRefinement(
            in: database,
            eventID: eventID,
            originalSamples: originalPoints,
            refinedPoints: refined,
            record: makeRecord(eventID: eventID, refinedCount: refined.count)
        )

        try Persistence.revertRefinement(in: database, eventID: eventID)

        // After revert there are no path_points rows under the activity id — original
        // samples live in the sibling path event and the main map renderer falls back to
        // time-slicing them. The refinement audit + snapshot are gone.
        let restored = try Persistence.fetchPathPoints(in: database, eventID: eventID)
        XCTAssertTrue(restored.isEmpty)
        XCTAssertNil(try Persistence.refinement(in: database, eventID: eventID))
        XCTAssertEqual(try originalCount(eventID: eventID), 0)
    }

    func testApplyClearsSkippedFlag() throws {
        let eventID = try seedTripWithPath(points: originalPoints)
        try Persistence.markSkipped(in: database, eventID: eventID, reason: .userRejected)
        XCTAssertTrue(try Persistence.isSkipped(in: database, eventID: eventID))

        try Persistence.applyRefinement(
            in: database,
            eventID: eventID,
            originalSamples: originalPoints,
            refinedPoints: [Coordinate(latitude: 0, longitude: 0)],
            record: makeRecord(eventID: eventID, refinedCount: 1)
        )
        XCTAssertFalse(try Persistence.isSkipped(in: database, eventID: eventID))
    }

    func testMultiLegApplyCreatesDerivedActivitiesAndSupersedesOriginal() throws {
        let eventID = try seedTripWithPath(points: originalPoints)
        // Need the original event's time window set sensibly so leg subdivision works.
        try database.execute("""
            UPDATE events SET start_ts = 1700000000, end_ts = 1700001800 WHERE id = '\(eventID.uuidString)';
        """)

        let legs = [
            LegInput(
                mode: "transit",
                label: "Bus 38",
                coordinates: [
                    Coordinate(latitude: 48.86, longitude: 2.35),
                    Coordinate(latitude: 48.865, longitude: 2.355),
                ],
                distanceMeters: 600,
                travelTimeSeconds: 600
            ),
            LegInput(
                mode: "walking",
                label: nil,
                coordinates: [
                    Coordinate(latitude: 48.865, longitude: 2.355),
                    Coordinate(latitude: 48.867, longitude: 2.357),
                ],
                distanceMeters: 200,
                travelTimeSeconds: 240
            ),
            LegInput(
                mode: "transit",
                label: "Bus 12",
                coordinates: [
                    Coordinate(latitude: 48.867, longitude: 2.357),
                    Coordinate(latitude: 48.870, longitude: 2.360),
                ],
                distanceMeters: 400,
                travelTimeSeconds: 360
            ),
        ]
        try Persistence.applyMultiLegRefinement(
            in: database,
            originalEventID: eventID,
            originalSamples: originalPoints,
            legs: legs,
            record: makeRecord(eventID: eventID, refinedCount: 6)
        )

        // Three derived events created.
        let derivedCountStmt = try database.prepare(
            "SELECT count(*) FROM events WHERE derived_from_event_id = ?;"
        )
        defer { derivedCountStmt.finalize() }
        try derivedCountStmt.bind(1, text: eventID.uuidString)
        XCTAssertEqual(derivedCountStmt.step(), .row)
        XCTAssertEqual(derivedCountStmt.columnInt(0), 3)

        // Original is superseded.
        let supersededStmt = try database.prepare(
            "SELECT is_superseded FROM events WHERE id = ?;"
        )
        defer { supersededStmt.finalize() }
        try supersededStmt.bind(1, text: eventID.uuidString)
        XCTAssertEqual(supersededStmt.step(), .row)
        XCTAssertEqual(supersededStmt.columnInt(0), 1)

        // Original snapshot stored.
        XCTAssertEqual(try originalCount(eventID: eventID), originalPoints.count)
    }

    func testMultiLegRevertRestoresOriginalAndDropsDerived() throws {
        let eventID = try seedTripWithPath(points: originalPoints)
        try database.execute("""
            UPDATE events SET start_ts = 1700000000, end_ts = 1700001800 WHERE id = '\(eventID.uuidString)';
        """)
        let legs = [
            LegInput(mode: "walking", label: nil, coordinates: [
                Coordinate(latitude: 48.86, longitude: 2.35),
                Coordinate(latitude: 48.862, longitude: 2.352),
            ], distanceMeters: 250, travelTimeSeconds: 200),
            LegInput(mode: "transit", label: "Line 4", coordinates: [
                Coordinate(latitude: 48.862, longitude: 2.352),
                Coordinate(latitude: 48.870, longitude: 2.360),
            ], distanceMeters: 1000, travelTimeSeconds: 480),
        ]
        try Persistence.applyMultiLegRefinement(
            in: database,
            originalEventID: eventID,
            originalSamples: originalPoints,
            legs: legs,
            record: makeRecord(eventID: eventID, refinedCount: 4)
        )

        try Persistence.revertRefinement(in: database, eventID: eventID)

        // All derived events removed.
        let derivedCountStmt = try database.prepare(
            "SELECT count(*) FROM events WHERE derived_from_event_id = ?;"
        )
        defer { derivedCountStmt.finalize() }
        try derivedCountStmt.bind(1, text: eventID.uuidString)
        XCTAssertEqual(derivedCountStmt.step(), .row)
        XCTAssertEqual(derivedCountStmt.columnInt(0), 0)

        // Original un-superseded and audit gone.
        let supersededStmt = try database.prepare(
            "SELECT is_superseded FROM events WHERE id = ?;"
        )
        defer { supersededStmt.finalize() }
        try supersededStmt.bind(1, text: eventID.uuidString)
        XCTAssertEqual(supersededStmt.step(), .row)
        XCTAssertEqual(supersededStmt.columnInt(0), 0)
        XCTAssertNil(try Persistence.refinement(in: database, eventID: eventID))
    }

    func testJourneyApplySupersedesAllMembersAndStoresMemberIDs() throws {
        // Seed three activity events (a journey of 3 legs).
        let walkID = UUID()
        let busID = UUID()
        let walk2ID = UUID()
        try seedActivity(id: walkID)
        try seedActivity(id: busID)
        try seedActivity(id: walk2ID)
        try database.execute("""
            UPDATE events SET start_ts = 1700000000, end_ts = 1700003600
            WHERE id IN ('\(walkID.uuidString)', '\(busID.uuidString)', '\(walk2ID.uuidString)');
        """)

        let legs = [
            LegInput(mode: "walking", label: nil, coordinates: [
                Coordinate(latitude: 0, longitude: 0),
                Coordinate(latitude: 0.01, longitude: 0.01),
            ], distanceMeters: 500, travelTimeSeconds: 300),
            LegInput(mode: "transit", label: "Bus 38", coordinates: [
                Coordinate(latitude: 0.01, longitude: 0.01),
                Coordinate(latitude: 0.05, longitude: 0.05),
            ], distanceMeters: 3000, travelTimeSeconds: 900),
        ]
        let journeyIDs = [walkID, busID, walk2ID]
        let record = RefinementRecord(
            eventID: walkID,
            refinedAt: Date(timeIntervalSince1970: 1_700_000_500),
            source: "google_maps",
            routeName: "Journey",
            transportType: "transit",
            similarityMeanMeters: 8,
            similarityP95Meters: 18,
            similarityMaxMeters: 25,
            expectedTravelTimeSeconds: 1200,
            expectedDistanceMeters: 3500,
            candidateCount: 2,
            chosenIndex: 0,
            originalPointCount: 12,
            refinedPointCount: 4,
            journeyMemberIDs: journeyIDs
        )

        try Persistence.applyJourneyRefinement(
            in: database,
            primaryEventID: walkID,
            supersededEventIDs: journeyIDs,
            journeyStartTs: 1_700_000_000,
            journeyEndTs: 1_700_001_800,
            timezoneOffsetMin: 0,
            source: "google_maps",
            originalSamples: [Coordinate(latitude: 0, longitude: 0)],
            legs: legs,
            record: record
        )

        // All 3 originals superseded.
        let supersededCount = try database.prepare(
            "SELECT count(*) FROM events WHERE is_superseded = 1 AND id IN (?, ?, ?);"
        )
        defer { supersededCount.finalize() }
        try supersededCount.bind(1, text: walkID.uuidString)
        try supersededCount.bind(2, text: busID.uuidString)
        try supersededCount.bind(3, text: walk2ID.uuidString)
        XCTAssertEqual(supersededCount.step(), .row)
        XCTAssertEqual(supersededCount.columnInt(0), 3)

        // 2 derived events linked to the primary.
        let derivedCount = try database.prepare(
            "SELECT count(*) FROM events WHERE derived_from_event_id = ?;"
        )
        defer { derivedCount.finalize() }
        try derivedCount.bind(1, text: walkID.uuidString)
        XCTAssertEqual(derivedCount.step(), .row)
        XCTAssertEqual(derivedCount.columnInt(0), 2)

        // Audit row carries the member list.
        let read = try XCTUnwrap(Persistence.refinement(in: database, eventID: walkID))
        XCTAssertEqual(read.journeyMemberIDs?.sorted(by: { $0.uuidString < $1.uuidString }),
                       journeyIDs.sorted(by: { $0.uuidString < $1.uuidString }))
    }

    func testJourneyRevertUnsupersedesAllMembersAndDropsDerived() throws {
        let walkID = UUID()
        let busID = UUID()
        try seedActivity(id: walkID)
        try seedActivity(id: busID)
        try database.execute("""
            UPDATE events SET start_ts = 1700000000, end_ts = 1700001800
            WHERE id IN ('\(walkID.uuidString)', '\(busID.uuidString)');
        """)

        let legs = [
            LegInput(mode: "walking", label: nil, coordinates: [
                Coordinate(latitude: 0, longitude: 0),
                Coordinate(latitude: 0.001, longitude: 0.001),
            ], distanceMeters: 250, travelTimeSeconds: 200),
            LegInput(mode: "transit", label: "Line 4", coordinates: [
                Coordinate(latitude: 0.001, longitude: 0.001),
                Coordinate(latitude: 0.05, longitude: 0.05),
            ], distanceMeters: 4000, travelTimeSeconds: 1200),
        ]
        let journeyIDs = [walkID, busID]
        try Persistence.applyJourneyRefinement(
            in: database,
            primaryEventID: walkID,
            supersededEventIDs: journeyIDs,
            journeyStartTs: 1_700_000_000,
            journeyEndTs: 1_700_001_800,
            timezoneOffsetMin: 0,
            source: "google_maps",
            originalSamples: [Coordinate(latitude: 0, longitude: 0)],
            legs: legs,
            record: RefinementRecord(
                eventID: walkID,
                refinedAt: Date(timeIntervalSince1970: 1_700_000_500),
                source: "google_maps",
                routeName: nil,
                transportType: "transit",
                similarityMeanMeters: 5,
                similarityP95Meters: 12,
                similarityMaxMeters: 20,
                expectedTravelTimeSeconds: 1400,
                expectedDistanceMeters: 4250,
                candidateCount: 1,
                chosenIndex: 0,
                originalPointCount: 1,
                refinedPointCount: 4,
                journeyMemberIDs: journeyIDs
            )
        )

        try Persistence.revertRefinement(in: database, eventID: walkID)

        // Both originals un-superseded.
        let supersededCount = try database.prepare(
            "SELECT count(*) FROM events WHERE is_superseded = 1 AND id IN (?, ?);"
        )
        defer { supersededCount.finalize() }
        try supersededCount.bind(1, text: walkID.uuidString)
        try supersededCount.bind(2, text: busID.uuidString)
        XCTAssertEqual(supersededCount.step(), .row)
        XCTAssertEqual(supersededCount.columnInt(0), 0)

        // No derived events left, no audit row.
        let derivedCount = try database.prepare(
            "SELECT count(*) FROM events WHERE derived_from_event_id = ?;"
        )
        defer { derivedCount.finalize() }
        try derivedCount.bind(1, text: walkID.uuidString)
        XCTAssertEqual(derivedCount.step(), .row)
        XCTAssertEqual(derivedCount.columnInt(0), 0)
        XCTAssertNil(try Persistence.refinement(in: database, eventID: walkID))
    }

    func testJourneyRevertFromDerivedSubActivityUnsupersedesAllMembersAndDropsAllDerived() throws {
        // Mirrors the bug scenario: user long-presses a *derived* leg (D2) of a journey
        // refinement and reverts. The controller resolves parentEventID(D2) -> A then
        // calls revertRefinement(A). All originals (A, B, C) must come back and all
        // derived (D1, D2, D3) must disappear.
        let aID = UUID()
        let bID = UUID()
        let cID = UUID()
        try seedActivity(id: aID)
        try seedActivity(id: bID)
        try seedActivity(id: cID)
        try database.execute("""
            UPDATE events SET start_ts = 1700000000, end_ts = 1700003600
            WHERE id IN ('\(aID.uuidString)', '\(bID.uuidString)', '\(cID.uuidString)');
        """)

        let legs = [
            LegInput(mode: "walking", label: nil, coordinates: [
                Coordinate(latitude: 0, longitude: 0),
                Coordinate(latitude: 0.001, longitude: 0.001),
            ], distanceMeters: 250, travelTimeSeconds: 200),
            LegInput(mode: "bus", label: "Bus 38", coordinates: [
                Coordinate(latitude: 0.001, longitude: 0.001),
                Coordinate(latitude: 0.05, longitude: 0.05),
            ], distanceMeters: 4000, travelTimeSeconds: 900),
            LegInput(mode: "walking", label: nil, coordinates: [
                Coordinate(latitude: 0.05, longitude: 0.05),
                Coordinate(latitude: 0.051, longitude: 0.051),
            ], distanceMeters: 200, travelTimeSeconds: 180),
        ]
        let journeyIDs = [aID, bID, cID]
        try Persistence.applyJourneyRefinement(
            in: database,
            primaryEventID: aID,
            supersededEventIDs: journeyIDs,
            journeyStartTs: 1_700_000_000,
            journeyEndTs: 1_700_003_600,
            timezoneOffsetMin: 0,
            source: "google_maps",
            originalSamples: [Coordinate(latitude: 0, longitude: 0)],
            legs: legs,
            record: RefinementRecord(
                eventID: aID,
                refinedAt: Date(timeIntervalSince1970: 1_700_000_500),
                source: "google_maps",
                routeName: nil,
                transportType: "transit",
                similarityMeanMeters: 5,
                similarityP95Meters: 12,
                similarityMaxMeters: 20,
                expectedTravelTimeSeconds: 1400,
                expectedDistanceMeters: 4450,
                candidateCount: 1,
                chosenIndex: 0,
                originalPointCount: 1,
                refinedPointCount: 6,
                journeyMemberIDs: journeyIDs
            )
        )

        // Pull the middle derived event id (D2) — the leg the user long-pressed.
        let derivedStmt = try database.prepare("""
            SELECT id FROM events WHERE derived_from_event_id = ? ORDER BY start_ts ASC;
        """)
        defer { derivedStmt.finalize() }
        try derivedStmt.bind(1, text: aID.uuidString)
        var derivedIDs: [UUID] = []
        while derivedStmt.step() == .row {
            if let text = derivedStmt.columnText(0), let id = UUID(uuidString: text) {
                derivedIDs.append(id)
            }
        }
        XCTAssertEqual(derivedIDs.count, 3, "expected three derived legs")
        let d2 = derivedIDs[1]

        // Simulate exactly what PathRefinementController.revert(trip:) does: look up the
        // parent of the long-pressed derived event then revert against the parent id.
        let parent = try Persistence.parentEventID(in: database, eventID: d2)
        XCTAssertEqual(parent, aID, "parentEventID(D2) must resolve to A — otherwise revert only touches the leaf")
        try Persistence.revertRefinement(in: database, eventID: parent ?? d2)

        // All 3 originals un-superseded.
        let supersededCount = try database.prepare(
            "SELECT count(*) FROM events WHERE is_superseded = 1 AND id IN (?, ?, ?);"
        )
        defer { supersededCount.finalize() }
        try supersededCount.bind(1, text: aID.uuidString)
        try supersededCount.bind(2, text: bID.uuidString)
        try supersededCount.bind(3, text: cID.uuidString)
        XCTAssertEqual(supersededCount.step(), .row)
        XCTAssertEqual(supersededCount.columnInt(0), 0, "every journey member must be un-superseded")

        // Zero derived events left.
        let derivedCount = try database.prepare(
            "SELECT count(*) FROM events WHERE derived_from_event_id = ?;"
        )
        defer { derivedCount.finalize() }
        try derivedCount.bind(1, text: aID.uuidString)
        XCTAssertEqual(derivedCount.step(), .row)
        XCTAssertEqual(derivedCount.columnInt(0), 0, "every derived leg must be deleted")

        // No audit row, no snapshot.
        XCTAssertNil(try Persistence.refinement(in: database, eventID: aID))
        XCTAssertEqual(try originalCount(eventID: aID), 0)
    }

    func testFetchRefinedActivityIDsIncludesDirectAndDerived() throws {
        // Seed two activities. One gets a single-trip refinement (audit row keyed to it),
        // the other becomes the primary for a multi-leg refinement (two derived activities).
        // Both originals must appear; derived activities count too.
        let walkID = UUID()
        let busID = UUID()
        try seedActivity(id: walkID)
        try seedActivity(id: busID)
        try database.execute("""
            UPDATE events SET start_ts = 1700000000, end_ts = 1700001800
            WHERE id IN ('\(walkID.uuidString)', '\(busID.uuidString)');
        """)

        // Single-leg refinement on `walkID`.
        try Persistence.applyRefinement(
            in: database,
            eventID: walkID,
            originalSamples: [Coordinate(latitude: 0, longitude: 0)],
            refinedPoints: [
                Coordinate(latitude: 0.001, longitude: 0.001),
                Coordinate(latitude: 0.002, longitude: 0.002),
            ],
            record: makeRecord(eventID: walkID, refinedCount: 2)
        )

        // Multi-leg refinement on `busID` — creates derived events.
        try Persistence.applyMultiLegRefinement(
            in: database,
            originalEventID: busID,
            originalSamples: [Coordinate(latitude: 0, longitude: 0)],
            legs: [
                LegInput(mode: "walking", label: nil, coordinates: [
                    Coordinate(latitude: 0, longitude: 0),
                    Coordinate(latitude: 0.001, longitude: 0.001),
                ], distanceMeters: 200, travelTimeSeconds: 200),
                LegInput(mode: "bus", label: nil, coordinates: [
                    Coordinate(latitude: 0.001, longitude: 0.001),
                    Coordinate(latitude: 0.01, longitude: 0.01),
                ], distanceMeters: 1500, travelTimeSeconds: 600),
            ],
            record: makeRecord(eventID: busID, refinedCount: 4)
        )

        let day = Date(timeIntervalSince1970: 1700000000)
        let range = day ..< day.addingTimeInterval(86400)
        let ids = try Persistence.fetchRefinedActivityIDs(in: database, dayRange: range)

        // walkID is in via path_refinements row.
        XCTAssertTrue(ids.contains(walkID))
        // busID is in via path_refinements (it's the primary of a multi-leg).
        XCTAssertTrue(ids.contains(busID))
        // The two derived events from busID's multi-leg are also in via derived_from_event_id.
        // We assert there are at least 4 distinct ids total: walkID, busID, derived1, derived2.
        XCTAssertGreaterThanOrEqual(ids.count, 4)
    }

    func testMarkSkippedAndReadBack() throws {
        let eventID = UUID()
        try seedActivity(id: eventID)
        try Persistence.markSkipped(in: database, eventID: eventID, reason: .noCandidates)
        XCTAssertTrue(try Persistence.isSkipped(in: database, eventID: eventID))
        XCTAssertEqual(try Persistence.skipReason(in: database, eventID: eventID), .noCandidates)

        // Upsert with a new reason.
        try Persistence.markSkipped(in: database, eventID: eventID, reason: .lowScore)
        XCTAssertEqual(try Persistence.skipReason(in: database, eventID: eventID), .lowScore)
    }

    // MARK: - Fixtures

    private let originalPoints: [Coordinate] = [
        Coordinate(latitude: 48.8566, longitude: 2.3522),
        Coordinate(latitude: 48.8576, longitude: 2.3532),
        Coordinate(latitude: 48.8586, longitude: 2.3542),
        Coordinate(latitude: 48.8596, longitude: 2.3552),
    ]

    private func seedActivity(id: UUID) throws {
        let stmt = try database.prepare("""
            INSERT INTO events (id, kind, start_ts, start_tz_offset_min, end_ts, end_tz_offset_min, source, imported_at)
            VALUES (?, 'activity', 1, 0, 2, 0, 'test', 1);
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: id.uuidString)
        try stmt.stepDone()
    }

    private func seedTripWithPath(points: [Coordinate]) throws -> UUID {
        let eventID = UUID()
        try seedActivity(id: eventID)
        let pathStmt = try database.prepare("""
            INSERT INTO path_points (event_id, seq, offset_min, lat, lon) VALUES (?, ?, ?, ?, ?);
        """)
        defer { pathStmt.finalize() }
        for (seq, point) in points.enumerated() {
            try pathStmt.reset()
            try pathStmt.bind(1, text: eventID.uuidString)
            try pathStmt.bind(2, int: seq)
            try pathStmt.bind(3, int: seq)
            try pathStmt.bind(4, double: point.latitude)
            try pathStmt.bind(5, double: point.longitude)
            try pathStmt.stepDone()
        }
        return eventID
    }

    private func originalCount(eventID: UUID) throws -> Int {
        let stmt = try database.prepare("SELECT count(*) FROM path_points_original WHERE event_id = ?;")
        defer { stmt.finalize() }
        try stmt.bind(1, text: eventID.uuidString)
        XCTAssertEqual(stmt.step(), .row)
        return stmt.columnInt(0)
    }

    private func makeRecord(eventID: UUID, refinedCount: Int) -> RefinementRecord {
        RefinementRecord(
            eventID: eventID,
            refinedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: "apple_maps",
            routeName: "Test route",
            transportType: "walking",
            similarityMeanMeters: 12.3,
            similarityP95Meters: 25.0,
            similarityMaxMeters: 40.0,
            expectedTravelTimeSeconds: 600,
            expectedDistanceMeters: 1200,
            candidateCount: 2,
            chosenIndex: 0,
            originalPointCount: 4,
            refinedPointCount: refinedCount
        )
    }
}
