import Foundation

/// Versioned SQL schema. Bump `currentVersion` and add a new entry in `Migrations.steps`
/// when the on-disk shape changes.
public enum Schema {
    public static let currentVersion: Int32 = 1

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
