/// The on-disk shape of the app.
///
/// Two ideas run through this schema.
///
/// The first is that telemetry is an append-only event log. `signal_readings`
/// is the only source of truth about what a vehicle reported; everything else
/// in here can be thrown away and rebuilt from it. That is what makes late and
/// out-of-order packets tractable: we never have to patch a running total, we
/// re-derive.
///
/// The second is that reading the log directly for every screen refresh would
/// be silly. A fleet list that scans two million rows to find 500 current
/// values is doing the wrong work. So the log has projections beside it --
/// `latest_readings` for current state, `geofence_events` and `trips` for
/// derived history -- which are maintained on write and are always
/// reconstructible from the log. Query cost then tracks the size of the fleet
/// rather than the size of its history.
library;

const int schemaVersion = 1;

/// Statements are applied in order inside one transaction on first open.
const List<String> schemaStatements = [
  '''
  CREATE TABLE IF NOT EXISTS meta (
    key   VARCHAR PRIMARY KEY,
    value VARCHAR NOT NULL
  )
  ''',

  // ---------------------------------------------------------------- fleet
  '''
  CREATE TABLE IF NOT EXISTS vehicles (
    vehicle_id VARCHAR PRIMARY KEY,
    reg_no     VARCHAR NOT NULL,
    model      VARCHAR NOT NULL
  )
  ''',

  // ------------------------------------------------------- the event log
  //
  // One row per (packet, signal). Values are DOUBLE across the board;
  // ignition is 0/1. A single narrow table means one ingest path, one
  // retention policy and one place to look, and it costs nothing in a
  // columnar store.
  //
  // event_time is what the vehicle says; ingest_time is when we stored it.
  // Keeping both is the whole game: freshness and ordering are decided on
  // event_time, while ingest_time is what lets us tell a late packet from an
  // old one and reason about what we knew when.
  '''
  CREATE TABLE IF NOT EXISTS signal_readings (
    vehicle_id  VARCHAR   NOT NULL,
    signal      VARCHAR   NOT NULL,
    event_time  TIMESTAMP NOT NULL,
    ingest_time TIMESTAMP NOT NULL,
    value       DOUBLE    NOT NULL,
    packet_id   VARCHAR   NOT NULL
  )
  ''',

  // The dedupe ledger.
  //
  // packet_id is either supplied by the device or, when it is not, derived
  // from the packet's content (vehicle, event time, and the sorted signal
  // payload). That second case matters: a modem that retransmits without an
  // id still produces a byte-identical packet, and hashing the content means
  // the retry collapses onto the same primary key instead of doubling a
  // reading. Idempotency is therefore a property of the table, not of
  // carefully written application code.
  '''
  CREATE TABLE IF NOT EXISTS packets (
    packet_id   VARCHAR PRIMARY KEY,
    vehicle_id  VARCHAR NOT NULL,
    event_time  TIMESTAMP NOT NULL,
    ingest_time TIMESTAMP NOT NULL,
    signal_count INTEGER NOT NULL
  )
  ''',

  // Packets we refused, kept so that "why is this truck missing" has an
  // answer. Silent drops are how you lose an afternoon.
  '''
  CREATE TABLE IF NOT EXISTS rejected_packets (
    packet_id   VARCHAR,
    vehicle_id  VARCHAR,
    event_time  TIMESTAMP,
    ingest_time TIMESTAMP NOT NULL,
    reason      VARCHAR NOT NULL
  )
  ''',

  // ------------------------------------------------- current-state projection
  //
  // The guard on the upsert is the entire late-packet rule for current state:
  // a reading only becomes "latest" if its event time beats what is already
  // there. A packet that arrives late still lands in the log, still shows up
  // in history, still moves geofences and trips -- it just does not get to
  // rewrite the present.
  '''
  CREATE TABLE IF NOT EXISTS latest_readings (
    vehicle_id VARCHAR   NOT NULL,
    signal     VARCHAR   NOT NULL,
    event_time TIMESTAMP NOT NULL,
    value      DOUBLE    NOT NULL,
    PRIMARY KEY (vehicle_id, signal)
  )
  ''',

  // ----------------------------------------------------------- geofences
  //
  // Geofences are versioned rather than mutable, because editing one would
  // otherwise rewrite history. If an operator widens the depot fence from
  // 150 m to 400 m this afternoon, last week's trips must not silently
  // re-evaluate against the new radius -- a truck that genuinely left the
  // depot in April did not un-leave it because someone moved a circle in
  // September. Occupancy at event time T is evaluated against the version
  // whose validity window contains T.
  //
  // Deactivation is just another version with active = false, which is how
  // deactivated fences stay available to trip history.
  '''
  CREATE TABLE IF NOT EXISTS geofences (
    geofence_id VARCHAR PRIMARY KEY,
    created_at  TIMESTAMP NOT NULL
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS geofence_versions (
    geofence_id VARCHAR   NOT NULL,
    version     INTEGER   NOT NULL,
    name        VARCHAR   NOT NULL,
    lat         DOUBLE    NOT NULL,
    lon         DOUBLE    NOT NULL,
    radius_m    DOUBLE    NOT NULL,
    active      BOOLEAN   NOT NULL,
    valid_from  TIMESTAMP NOT NULL,
    valid_to    TIMESTAMP,
    PRIMARY KEY (geofence_id, version)
  )
  ''',

  // Confirmed transitions, derived from the log.
  //
  // `uncertain` and `window_start` carry the honesty: when the fix that
  // confirms a crossing is hours after the last fix on the other side, we
  // record when we found out and how wide the window of ignorance was,
  // instead of inventing a crossing time we cannot know.
  '''
  CREATE TABLE IF NOT EXISTS geofence_events (
    vehicle_id   VARCHAR   NOT NULL,
    geofence_id  VARCHAR   NOT NULL,
    kind         VARCHAR   NOT NULL,
    event_time   TIMESTAMP NOT NULL,
    window_start TIMESTAMP,
    uncertain    BOOLEAN   NOT NULL,
    PRIMARY KEY (vehicle_id, geofence_id, kind, event_time)
  )
  ''',

  // --------------------------------------------------------------- trips
  '''
  CREATE TABLE IF NOT EXISTS trips (
    trip_id                 VARCHAR PRIMARY KEY,
    vehicle_id              VARCHAR   NOT NULL,
    origin_geofence_id      VARCHAR,
    started_at              TIMESTAMP NOT NULL,
    destination_geofence_id VARCHAR,
    ended_at                TIMESTAMP,
    status                  VARCHAR   NOT NULL,
    start_uncertain         BOOLEAN   NOT NULL DEFAULT FALSE,
    end_uncertain           BOOLEAN   NOT NULL DEFAULT FALSE,
    distance_km             DOUBLE
  )
  ''',

  // -------------------------------------------------------------- alerts
  //
  // A row is one *instance* of a condition: it opens when the condition is
  // first seen on a fresh reading, and closes when a fresh reading shows the
  // condition gone. Dismissal is an annotation on the instance, not a
  // deletion, which is what makes the two lifecycles independent in the way
  // the spec asks for: dismissing does not resolve, resolving does not care
  // whether you dismissed, and a condition that clears and later returns
  // opens a *new* instance that is undismissed and visible again. That last
  // point is the one that would bite an operator -- dismissing "low battery"
  // on Monday must not hide Tuesday's.
  '''
  CREATE TABLE IF NOT EXISTS alerts (
    alert_id       VARCHAR PRIMARY KEY,
    vehicle_id     VARCHAR   NOT NULL,
    kind           VARCHAR   NOT NULL,
    severity       VARCHAR   NOT NULL,
    trigger_value  DOUBLE    NOT NULL,
    opened_at      TIMESTAMP NOT NULL,
    last_seen_at   TIMESTAMP NOT NULL,
    resolved_at    TIMESTAMP,
    dismissed_at   TIMESTAMP,
    dismiss_reason VARCHAR
  )
  ''',

  // ------------------------------------------------------ rollup / retention
  '''
  CREATE TABLE IF NOT EXISTS signal_rollups (
    vehicle_id   VARCHAR   NOT NULL,
    signal       VARCHAR   NOT NULL,
    bucket_start TIMESTAMP NOT NULL,
    min_value    DOUBLE    NOT NULL,
    max_value    DOUBLE    NOT NULL,
    last_value   DOUBLE    NOT NULL,
    sample_count INTEGER   NOT NULL,
    PRIMARY KEY (vehicle_id, signal, bucket_start)
  )
  ''',

  // ------------------------------------------------------------- views
  //
  // A position fix is three signals that arrived in one packet. Rather than
  // give location its own table (and its own ingest path, and its own
  // retention rule), we keep it in the log like everything else and pivot it
  // back into fixes here. Grouping on event_time is safe because those three
  // rows come from the same packet and therefore carry the same event time
  // by construction.
  '''
  CREATE OR REPLACE VIEW location_fixes AS
  SELECT * FROM (
    SELECT
      vehicle_id,
      event_time,
      min(ingest_time)                                       AS ingest_time,
      max(value) FILTER (WHERE signal = 'lat')               AS lat,
      max(value) FILTER (WHERE signal = 'lon')               AS lon,
      max(value) FILTER (WHERE signal = 'gps_accuracy_m')    AS accuracy_m,
      min(packet_id)                                         AS packet_id
    FROM signal_readings
    WHERE signal IN ('lat', 'lon', 'gps_accuracy_m')
    GROUP BY vehicle_id, event_time
  )
  WHERE lat IS NOT NULL AND lon IS NOT NULL
  ''',

  // "Last ping" is the newest event time we hold for a vehicle across any
  // signal. Reading it off the projection rather than the log keeps it O(one
  // row per signal per vehicle) instead of O(history).
  '''
  CREATE OR REPLACE VIEW vehicle_last_ping AS
  SELECT vehicle_id, max(event_time) AS last_ping
  FROM latest_readings
  GROUP BY vehicle_id
  ''',

  // The current definition of each geofence.
  '''
  CREATE OR REPLACE VIEW geofences_current AS
  SELECT g.geofence_id, v.version, v.name, v.lat, v.lon, v.radius_m,
         v.active, v.valid_from
  FROM geofences g
  JOIN geofence_versions v USING (geofence_id)
  WHERE v.valid_to IS NULL
  ''',
];
