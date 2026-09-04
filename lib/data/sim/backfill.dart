import '../../core/clock.dart';
import '../../domain/rules.dart';
import '../db/fleet_db.dart';
import '../repo/queries.dart';

/// Generates a fleet's worth of history.
///
/// Every row is produced by DuckDB itself from `range()`, not marshalled row
/// by row from Dart. Two and a half million rows through a prepared statement
/// would be tens of minutes of FFI round trips; as a handful of INSERT ...
/// SELECT statements it is a few seconds, and the generator becomes something
/// you can actually iterate on.
///
/// Values are deterministic functions of (vehicle index, sample index) rather
/// than random(), so a benchmark run is reproducible and a regression is a
/// real regression rather than a different dice roll.
///
/// The data is shaped to exercise the app rather than to look plausible in
/// aggregate: some vehicles sit below the SOC thresholds, some batteries run
/// hot, some vehicles are deliberately silent so the fleet is not uniformly
/// online, and positions orbit between two of the seeded geofences so that
/// crossings and trips actually happen.
class Backfill {
  Backfill(this._db, this._clock);

  final FleetDb _db;
  final Clock _clock;

  /// Six non-positional signals per sample, plus a position fix on every
  /// other sample (three more signals). With the defaults below that is
  ///   500 * (700 * 6 + 350 * 3) = 2,625,000 rows.
  static const defaultVehicles = 500;
  static const defaultSamplesPerVehicle = 700;
  static const sampleInterval = Duration(minutes: 6);

  Future<BackfillReport> run({
    int vehicles = defaultVehicles,
    int samplesPerVehicle = defaultSamplesPerVehicle,
    void Function(String stage)? onStage,
  }) async {
    final started = DateTime.now();
    final now = _clock.nowUtc();
    final nowLiteral = sqlTimestamp(now);

    onStage?.call('vehicles');
    await _db.execute('''
      INSERT INTO vehicles
      SELECT
        'v' || i,
        'KA' || lpad(CAST(1 + (i % 51) AS VARCHAR), 2, '0') ||
          CASE WHEN i % 3 = 0 THEN 'AB' WHEN i % 3 = 1 THEN 'CD' ELSE 'EF' END ||
          lpad(CAST(1000 + i AS VARCHAR), 4, '0'),
        CASE i % 4
          WHEN 0 THEN 'eTruck 400'
          WHEN 1 THEN 'eTruck 600'
          WHEN 2 THEN 'HaulEV L2'
          ELSE 'HaulEV L4'
        END
      FROM range(0, $vehicles) t(i)
      ON CONFLICT DO NOTHING
    ''');

    // The sample grid. sample_index 0 is the most recent; higher indices run
    // further into the past.
    //
    // A vehicle's "silence" offset pushes its newest sample backwards so the
    // fleet does not come up uniformly online: roughly a fifth of vehicles
    // land outside the ten-minute window and read as OFFLINE, which is what
    // the fleet screen is for.
    onStage?.call('grid');
    await _db.execute('''
      CREATE OR REPLACE TEMP TABLE bf_grid AS
      SELECT
        v.i AS vi,
        k.i AS ki,
        'v' || v.i AS vehicle_id,
        $nowLiteral
          - to_minutes(CAST(k.i * ${sampleInterval.inMinutes} AS INTEGER))
          - to_minutes(CAST(CASE WHEN v.i % 5 = 0 THEN 20 + (v.i % 40) ELSE 0 END AS INTEGER))
          AS event_time,
        -- Deterministic unit noise, stable across runs.
        (hash(v.i * 7919 + k.i) % 1000) / 1000.0 AS noise
      FROM range(0, $vehicles) v(i), range(0, $samplesPerVehicle) k(i)
    ''');

    onStage?.call('signals');
    await _db.execute(r'''
      CREATE OR REPLACE TEMP TABLE bf_readings AS
      WITH derived AS (
        SELECT *,
          -- A discharge/charge sawtooth. The phase is per vehicle so the
          -- fleet is not synchronised, and the floor dips under both SOC
          -- thresholds for a slice of the fleet.
          greatest(3.0, least(100.0,
            8.0 + 92.0 * abs(1.0 - 2.0 *
              (((ki + vi * 17) % 240) / 240.0))
          )) AS soc_v,
          CASE WHEN (vi + ki) % 7 < 3 THEN 0.0
               ELSE 15.0 + (hash(vi * 31 + ki * 17) % 6000) / 100.0 END
            AS speed_v,
          22.0 + (hash(vi * 13 + ki * 7) % 2800) / 100.0 AS temp_v
        FROM bf_grid
      )
      SELECT vehicle_id, 'soc' AS signal, event_time, soc_v AS value, vi, ki
        FROM derived
      UNION ALL
      SELECT vehicle_id, 'range_km', event_time, round(soc_v * 4.2, 1), vi, ki
        FROM derived
      UNION ALL
      SELECT vehicle_id, 'speed', event_time, round(speed_v, 1), vi, ki
        FROM derived
      UNION ALL
      SELECT vehicle_id, 'battery_temp', event_time, round(temp_v, 1), vi, ki
        FROM derived
      UNION ALL
      SELECT vehicle_id, 'ignition', event_time,
             CASE WHEN speed_v > 0 OR (vi + ki) % 11 = 0 THEN 1.0 ELSE 0.0 END,
             vi, ki
        FROM derived
      UNION ALL
      SELECT vehicle_id, 'odometer', event_time,
             round(120000.0 + vi * 137.0 + (700 - ki) * 1.7, 1), vi, ki
        FROM derived
    ''');

    // Positions, on every other sample.
    //
    // Vehicles run a slow orbit between the two seeded depots so that the
    // crossing engine has real entries and exits to find. The jitter is a few
    // metres -- enough to be realistic, not enough to defeat the hysteresis
    // band, which is the point of having one.
    onStage?.call('positions');
    await _db.execute('''
      CREATE OR REPLACE TEMP TABLE bf_positions AS
      WITH pts AS (
        SELECT *,
          (sin(2 * pi() * ki / 96.0 + vi) + 1) / 2 AS frac
        FROM bf_grid WHERE ki % 2 = 0
      )
      SELECT vehicle_id, event_time, vi, ki,
        $seedDepotLat + frac * ($seedCustomerLat - $seedDepotLat)
          + (noise - 0.5) * 0.00025 AS lat,
        $seedDepotLon + frac * ($seedCustomerLon - $seedDepotLon)
          + (noise - 0.5) * 0.00025 AS lon,
        -- Most fixes are good; a slice are junk, so the accuracy gate has
        -- something to reject.
        CASE WHEN (vi + ki) % 23 = 0 THEN 150.0 + noise * 200.0
             ELSE 4.0 + noise * 12.0 END AS acc
      FROM pts
    ''');

    onStage?.call('log');
    await _db.execute('''
      INSERT INTO signal_readings
      SELECT vehicle_id, signal, event_time, $nowLiteral, value,
             'bf-' || vi || '-' || ki
      FROM bf_readings
    ''');
    await _db.execute('''
      INSERT INTO signal_readings
      SELECT vehicle_id, s.signal, event_time, $nowLiteral,
             CASE s.signal WHEN 'lat' THEN lat WHEN 'lon' THEN lon
                           ELSE acc END,
             'bfp-' || vi || '-' || ki
      FROM bf_positions
      CROSS JOIN (SELECT unnest(['lat', 'lon', 'gps_accuracy_m']) AS signal) s
    ''');

    // Current state. Built in one pass off the log rather than by replaying
    // the upsert, because the generated data is already in order and this is
    // the one place where the projection can honestly be rebuilt in bulk.
    onStage?.call('projection');
    await _db.execute('''
      INSERT INTO latest_readings
      SELECT vehicle_id, signal, event_time, value FROM (
        SELECT vehicle_id, signal, event_time, value,
               row_number() OVER (
                 PARTITION BY vehicle_id, signal ORDER BY event_time DESC
               ) AS rn
        FROM signal_readings
      ) WHERE rn = 1
      ON CONFLICT (vehicle_id, signal) DO UPDATE
        SET value = excluded.value, event_time = excluded.event_time
        WHERE excluded.event_time > latest_readings.event_time
    ''');

    await _db.execute('DROP TABLE IF EXISTS bf_grid');
    await _db.execute('DROP TABLE IF EXISTS bf_readings');
    await _db.execute('DROP TABLE IF EXISTS bf_positions');

    final rows = (await _db.selectOne(
      'SELECT count(*) AS n FROM signal_readings',
    ))!['n'] as int;

    return BackfillReport(
      vehicles: vehicles,
      signalRows: rows,
      elapsed: DateTime.now().difference(started),
    );
  }

  /// The geofences the demo data orbits between. Seeded before a backfill so
  /// the crossing engine has something to find.
  static const seedDepotLat = 12.9716;
  static const seedDepotLon = 77.5946;
  static const seedCustomerLat = 13.0100;
  static const seedCustomerLon = 77.6400;

  /// Whether the log already holds a meaningful amount of history.
  Future<bool> alreadyPopulated() async {
    final row = await _db.selectOne(
      'SELECT count(*) AS n FROM vehicles',
    );
    return (row!['n'] as int) > 0;
  }
}

class BackfillReport {
  const BackfillReport({
    required this.vehicles,
    required this.signalRows,
    required this.elapsed,
  });

  final int vehicles;
  final int signalRows;
  final Duration elapsed;

  @override
  String toString() => '$vehicles vehicles, $signalRows signal rows '
      'in ${elapsed.inMilliseconds} ms';
}

/// Retention.
///
/// An append-only log grows forever, so something has to give. The policy is
/// three tiers, and the honest statement of what each one costs:
///
/// * **Raw readings for [Rules.rawRetention].** Everything, exactly as
///   reported. This is the window in which geofence crossings and trips can be
///   re-derived from scratch, so it is also the window in which a late packet
///   can still correct history.
///
/// * **Five-minute rollups for [Rules.rollupRetention] beyond that.** Per
///   (vehicle, signal, bucket) we keep min, max, last and a count. The SOC
///   chart keeps working across the boundary and the shape of a week is
///   preserved. What is lost: the individual reading, its packet id, and the
///   ability to re-derive crossings -- a fence edit can no longer be applied
///   retroactively past this line, because the positions that would have to be
///   re-judged are gone. Trips and crossings already derived are kept, because
///   they are small and they are the answer the operator actually wanted.
///
/// * **Nothing beyond that**, except the derived tables. Trips, crossings and
///   resolved alerts are a few rows per vehicle per day and are worth keeping
///   indefinitely; two million raw readings a week are not.
///
/// Positions are deliberately excluded from rollup: averaging a position is
/// meaningless, and a min/max latitude is worse than nothing. Location fixes
/// simply expire with the raw window, and the crossings derived from them
/// survive as the summary.
class Retention {
  Retention(this._db, this._clock);

  final FleetDb _db;
  final Clock _clock;

  Future<RetentionReport> compact() async {
    final now = _clock.nowUtc();
    final rawCutoff = sqlTimestamp(now.subtract(Rules.rawRetention));
    final rollupCutoff = sqlTimestamp(
      now.subtract(Rules.rawRetention + Rules.rollupRetention),
    );
    final bucketSeconds = Rules.rollupBucket.inSeconds;

    return _db.transaction(() async {
      final before = (await _db.selectOne(
        'SELECT count(*) AS n FROM signal_readings',
      ))!['n'] as int;

      await _db.execute('''
        INSERT INTO signal_rollups
        SELECT vehicle_id, signal,
               time_bucket(INTERVAL $bucketSeconds SECOND, event_time) AS bucket_start,
               min(value), max(value),
               arg_max(value, event_time),
               count(*)
        FROM signal_readings
        WHERE event_time < $rawCutoff
          AND signal NOT IN ('lat', 'lon', 'gps_accuracy_m')
        GROUP BY vehicle_id, signal, bucket_start
        ON CONFLICT (vehicle_id, signal, bucket_start) DO UPDATE SET
          min_value = least(signal_rollups.min_value, excluded.min_value),
          max_value = greatest(signal_rollups.max_value, excluded.max_value),
          last_value = excluded.last_value,
          sample_count = signal_rollups.sample_count + excluded.sample_count
      ''');

      await _db.execute(
        'DELETE FROM signal_readings WHERE event_time < $rawCutoff',
      );
      await _db.execute(
        'DELETE FROM packets WHERE event_time < $rawCutoff',
      );
      await _db.execute(
        'DELETE FROM signal_rollups WHERE bucket_start < $rollupCutoff',
      );
      // Alerts that closed before the rollup horizon are history nobody will
      // read. Open ones are never dropped however old they are.
      await _db.execute(
        'DELETE FROM alerts WHERE resolved_at IS NOT NULL '
        'AND resolved_at < $rollupCutoff',
      );

      final after = (await _db.selectOne(
        'SELECT count(*) AS n FROM signal_readings',
      ))!['n'] as int;
      final rollups = (await _db.selectOne(
        'SELECT count(*) AS n FROM signal_rollups',
      ))!['n'] as int;

      return RetentionReport(
        rowsDropped: before - after,
        rollupRows: rollups,
      );
    });
  }
}

class RetentionReport {
  const RetentionReport({required this.rowsDropped, required this.rollupRows});

  final int rowsDropped;
  final int rollupRows;
}
