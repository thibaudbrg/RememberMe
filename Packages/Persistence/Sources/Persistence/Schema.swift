import Foundation

/// Versioned SQL schema. Bump `currentVersion` and add a new entry in `Migrations.steps`
/// when the on-disk shape changes.
public enum Schema {
    public static let currentVersion: Int32 = 5

    /// v5 — Drop `idx_path_points_event`. It duplicates the `(event_id, seq)` PRIMARY KEY index on
    /// `path_points`, so every lookup/ORDER BY on `event_id` is already served by the PK; the extra
    /// index only added write amplification on the hottest insert path.
    public static let v5: String = """
    DROP INDEX idx_path_points_event;
    """

    /// v4 — Journey refinement. When a refinement covers a multi-row journey
    /// (walk→bus→visit→train→walk→destination), we need to remember which originals
    /// were superseded as part of it so revert can un-supersede precisely the right rows.
    public static let v4: String = """
    ALTER TABLE path_refinements ADD COLUMN journey_member_ids TEXT;
    """

    /// v3 — Multi-leg refinement support. Lets one recorded activity be replaced with N
    /// derived activities (e.g. bus → walk → bus) that link back to their parent.
    ///   - `derived_from_event_id` on `events` points a child activity at its parent.
    ///   - `is_superseded` marks the parent so timeline + map queries hide it.
    /// Existing events default to NULL / 0, so v2 data carries forward untouched.
    public static let v3: String = """
    ALTER TABLE events ADD COLUMN derived_from_event_id TEXT;
    ALTER TABLE events ADD COLUMN is_superseded INTEGER NOT NULL DEFAULT 0;
    CREATE INDEX idx_events_derived_from ON events(derived_from_event_id);
    CREATE INDEX idx_events_superseded ON events(is_superseded);
    """

    /// v2 — Path refinement alpha (originals snapshot + audit + skip ledger).
    public static let v2: String = """
    CREATE TABLE path_points_original (
        event_id   TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
        seq        INTEGER NOT NULL,
        offset_min INTEGER NOT NULL,
        lat        REAL NOT NULL,
        lon        REAL NOT NULL,
        PRIMARY KEY (event_id, seq)
    );

    CREATE TABLE path_refinements (
        event_id              TEXT PRIMARY KEY REFERENCES events(id) ON DELETE CASCADE,
        refined_at            INTEGER NOT NULL,
        source                TEXT NOT NULL,
        route_name            TEXT,
        transport_type        TEXT NOT NULL,
        similarity_mean_m     REAL NOT NULL,
        similarity_p95_m      REAL NOT NULL,
        similarity_max_m      REAL NOT NULL,
        expected_travel_s     REAL,
        expected_distance_m   REAL,
        candidate_count       INTEGER NOT NULL,
        chosen_index          INTEGER NOT NULL,
        original_point_count  INTEGER NOT NULL,
        refined_point_count   INTEGER NOT NULL
    );
    CREATE INDEX idx_refinements_refined_at ON path_refinements(refined_at);

    CREATE TABLE path_refinement_skips (
        event_id   TEXT PRIMARY KEY REFERENCES events(id) ON DELETE CASCADE,
        checked_at INTEGER NOT NULL,
        reason     TEXT NOT NULL
    );
    """

    /// Initial schema (v1). Matches the sketch in docs/architecture.md.
    public static let v1: String = """
    CREATE TABLE events (
        id                  TEXT PRIMARY KEY NOT NULL,
        kind                TEXT NOT NULL CHECK (kind IN ('activity','visit','path')),
        start_ts            INTEGER NOT NULL,
        start_tz_offset_min INTEGER NOT NULL,
        end_ts              INTEGER NOT NULL,
        end_tz_offset_min   INTEGER NOT NULL,
        source              TEXT NOT NULL,
        imported_at         INTEGER NOT NULL
    );

    CREATE INDEX idx_events_start_ts ON events(start_ts);
    CREATE INDEX idx_events_kind     ON events(kind);

    CREATE TABLE activities (
        event_id    TEXT PRIMARY KEY NOT NULL REFERENCES events(id) ON DELETE CASCADE,
        start_lat   REAL NOT NULL,
        start_lon   REAL NOT NULL,
        end_lat     REAL NOT NULL,
        end_lon     REAL NOT NULL,
        distance_m  REAL NOT NULL,
        mode        TEXT NOT NULL,
        probability REAL NOT NULL
    );

    CREATE TABLE visits (
        event_id        TEXT PRIMARY KEY NOT NULL REFERENCES events(id) ON DELETE CASCADE,
        place_id        TEXT NOT NULL,
        lat             REAL NOT NULL,
        lon             REAL NOT NULL,
        semantic_type   TEXT NOT NULL,
        hierarchy_level INTEGER NOT NULL,
        probability     REAL NOT NULL
    );

    CREATE INDEX idx_visits_place_id ON visits(place_id);

    CREATE TABLE path_points (
        event_id   TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
        seq        INTEGER NOT NULL,  -- 0-indexed position in the original path array
        offset_min INTEGER NOT NULL,
        lat        REAL NOT NULL,
        lon        REAL NOT NULL,
        PRIMARY KEY (event_id, seq)
    );

    CREATE INDEX idx_path_points_event ON path_points(event_id);

    CREATE TABLE places (
        place_id       TEXT PRIMARY KEY NOT NULL,
        user_label     TEXT,
        resolved_label TEXT,
        resolved_at    INTEGER,
        lat            REAL NOT NULL,
        lon            REAL NOT NULL
    );
    """
}
