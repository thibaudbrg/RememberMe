import Core
import XCTest
@testable import Persistence

/// Round-trips the encrypted backup path: populate a DB, `fetchExportPayload`, `restore` into a
/// fresh DB, compare. This is the app's only backup/recovery path, and previously had zero tests.
final class ExportQueriesTests: XCTestCase {
    private func freshDatabase() throws -> SQLCipherDatabase {
        try DatabaseFactory.open(
            at: SQLCipherDatabase.inMemoryPath,
            keyStore: InMemoryKeyStore(),
            excludeFromBackup: false
        )
    }

    func testExportRestoreRoundTripPreservesEventsPlacesAndPaths() throws {
        let source = try freshDatabase()

        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let activity = Event(
            start: TimestampedLocal(date: day, tzOffsetMinutes: 60),
            end: TimestampedLocal(date: day.addingTimeInterval(600), tzOffsetMinutes: 60),
            source: "takeout",
            kind: .activity(ActivityDetails(
                start: Coordinate(latitude: 48.0, longitude: 2.0),
                end: Coordinate(latitude: 48.1, longitude: 2.1),
                distanceMeters: 1234,
                mode: "walking",
                probability: 0.9
            ))
        )
        let visit = Event(
            start: TimestampedLocal(date: day, tzOffsetMinutes: 60),
            end: TimestampedLocal(date: day.addingTimeInterval(3600), tzOffsetMinutes: 60),
            source: "takeout",
            kind: .visit(VisitDetails(
                placeID: "home",
                location: Coordinate(latitude: 48.0, longitude: 2.0),
                semanticType: "Home",
                hierarchyLevel: 0,
                probability: 0.95
            ))
        )
        let path = Event(
            start: TimestampedLocal(date: day, tzOffsetMinutes: 60),
            end: TimestampedLocal(date: day.addingTimeInterval(600), tzOffsetMinutes: 60),
            source: "takeout",
            kind: .path([
                PathPoint(coordinate: Coordinate(latitude: 48.0, longitude: 2.0), offsetMinutes: 0),
                PathPoint(coordinate: Coordinate(latitude: 48.05, longitude: 2.05), offsetMinutes: 5),
                PathPoint(coordinate: Coordinate(latitude: 48.1, longitude: 2.1), offsetMinutes: 10),
            ])
        )
        try EventWriter(database: source).write([activity, visit, path])
        try Persistence.upsertPlace(
            in: source,
            placeID: "home",
            coordinate: Coordinate(latitude: 48.0, longitude: 2.0),
            resolvedLabel: "Home Street 1",
            resolvedAt: Date(timeIntervalSince1970: 1_700_500_000)
        )

        // Export from source, restore into a fresh DB.
        let payload = try Persistence.fetchExportPayload(in: source)
        let restored = try freshDatabase()
        let newCount = try Persistence.restore(payload: payload, in: restored)
        XCTAssertEqual(newCount, 3)

        // Events of each kind survive.
        XCTAssertEqual(try Persistence.eventCounts(in: restored), .init(total: 3, activities: 1, visits: 1, paths: 1))

        // Path geometry survives in order.
        let pathID = path.id
        let points = try Persistence.fetchPathPoints(in: restored, eventID: pathID)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.first?.latitude ?? 0, 48.0, accuracy: 1e-9)
        XCTAssertEqual(points.last?.latitude ?? 0, 48.1, accuracy: 1e-9)

        // Place + its resolved label survive.
        let place = try XCTUnwrap(Persistence.fetchPlace(in: restored, placeID: "home"))
        XCTAssertEqual(place.resolvedLabel, "Home Street 1")
    }

    func testRestoreIsIdempotentOnReimport() throws {
        let source = try freshDatabase()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        try EventWriter(database: source).write([
            Event(
                start: TimestampedLocal(date: day, tzOffsetMinutes: 0),
                end: TimestampedLocal(date: day.addingTimeInterval(600), tzOffsetMinutes: 0),
                source: "takeout",
                kind: .activity(ActivityDetails(
                    start: Coordinate(latitude: 1, longitude: 1),
                    end: Coordinate(latitude: 2, longitude: 2),
                    distanceMeters: 100,
                    mode: "walking",
                    probability: 0.9
                ))
            ),
        ])

        let payload = try Persistence.fetchExportPayload(in: source)
        let restored = try freshDatabase()
        XCTAssertEqual(try Persistence.restore(payload: payload, in: restored), 1)
        // Restoring the same payload again must add nothing — INSERT OR IGNORE on the event id.
        XCTAssertEqual(try Persistence.restore(payload: payload, in: restored), 0)
        XCTAssertEqual(try Persistence.eventCounts(in: restored).total, 1)
    }

    /// Payload v2 (H4): refinement state must survive a backup round trip — a superseded
    /// original must NOT be resurrected as a visible duplicate next to its derived legs.
    func testExportRestorePreservesSupersededAndDerivedState() throws {
        let source = try freshDatabase()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        func makeActivity() -> Event {
            Event(
                start: TimestampedLocal(date: day, tzOffsetMinutes: 0),
                end: TimestampedLocal(date: day.addingTimeInterval(600), tzOffsetMinutes: 0),
                source: "takeout",
                kind: .activity(ActivityDetails(
                    start: Coordinate(latitude: 1, longitude: 1),
                    end: Coordinate(latitude: 2, longitude: 2),
                    distanceMeters: 100,
                    mode: "walking",
                    probability: 0.9
                ))
            )
        }
        let original = makeActivity()
        let derived = makeActivity()
        try EventWriter(database: source).write([original, derived])
        try source.execute("UPDATE events SET is_superseded = 1 WHERE id = '\(original.id.uuidString)';")
        try source.execute("""
            UPDATE events SET derived_from_event_id = '\(original.id.uuidString)'
            WHERE id = '\(derived.id.uuidString)';
        """)

        let payload = try Persistence.fetchExportPayload(in: source)
        XCTAssertEqual(payload.version, 2)
        let exportedOriginal = try XCTUnwrap(payload.events.first { $0.id == original.id.uuidString })
        XCTAssertTrue(exportedOriginal.isSuperseded)
        let exportedDerived = try XCTUnwrap(payload.events.first { $0.id == derived.id.uuidString })
        XCTAssertEqual(exportedDerived.derivedFromEventID, original.id.uuidString)

        let restored = try freshDatabase()
        try Persistence.restore(payload: payload, in: restored)

        let stmt = try restored.prepare(
            "SELECT is_superseded, derived_from_event_id FROM events WHERE id = ?;"
        )
        defer { stmt.finalize() }
        try stmt.bind(1, text: original.id.uuidString)
        XCTAssertEqual(try stmt.step(), .row)
        XCTAssertEqual(stmt.columnInt(0), 1, "superseded original must stay hidden after restore")
        try stmt.reset()
        try stmt.bind(1, text: derived.id.uuidString)
        XCTAssertEqual(try stmt.step(), .row)
        XCTAssertEqual(stmt.columnText(1), original.id.uuidString, "derived lineage must survive restore")
    }

    /// A v1 payload (no refinement keys) must still decode, defaulting to not-superseded.
    func testV1PayloadWithoutRefinementKeysStillDecodes() throws {
        let v1JSON = """
        {"version": 1, "exported_at": 1700000000,
         "events": [{"id": "ABC", "kind": "visit", "start_ts": 1, "start_tz_offset_min": 0,
                     "end_ts": 2, "end_tz_offset_min": 0, "source": "takeout", "imported_at": 3}],
         "places": []}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let payload = try decoder.decode(ExportPayload.self, from: Data(v1JSON.utf8))
        XCTAssertEqual(payload.events.first?.isSuperseded, false)
        XCTAssertNil(payload.events.first?.derivedFromEventID)
    }

    /// The places upsert uses a NULL-safe MAX(resolved_at); a row whose stored `resolved_at` is
    /// NULL must not blow away the incoming label/timestamp on restore.
    func testRestorePlaceWithNullResolvedAtKeepsIncomingResolvedAt() throws {
        let restored = try freshDatabase()
        // Seed a place with a NULL resolved_at directly (e.g. a user_label-only row).
        try restored.execute("""
            INSERT INTO places (place_id, user_label, resolved_label, resolved_at, lat, lon)
            VALUES ('home', 'Home', NULL, NULL, 48.0, 2.0);
        """)

        let payload = ExportPayload(
            exportedAt: Date(),
            events: [],
            places: [ExportedPlace(
                placeID: "home",
                userLabel: nil,
                resolvedLabel: "Resolved Home",
                resolvedAt: 1_700_500_000,
                lat: 48.0,
                lon: 2.0
            )]
        )
        try Persistence.restore(payload: payload, in: restored)

        let place = try XCTUnwrap(Persistence.fetchPlace(in: restored, placeID: "home"))
        XCTAssertEqual(place.resolvedLabel, "Resolved Home")
        XCTAssertEqual(place.userLabel, "Home")
        XCTAssertEqual(
            place.resolvedAt,
            Date(timeIntervalSince1970: 1_700_500_000),
            "NULL-safe MAX must take the incoming resolved_at over a NULL stored value"
        )
    }
}
