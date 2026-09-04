import '../../domain/engine/geofence_engine.dart';
import '../../domain/engine/trip_engine.dart';
import '../db/fleet_db.dart';

/// Persists the derived layers: geofence crossings and the trips built on top
/// of them.
///
/// **Why this replays a vehicle wholesale rather than appending.**
///
/// The obvious optimisation is to fold only the new fixes onto the state we
/// left off at. The problem is that "the state we left off at" is not
/// well-defined once packets can arrive late: a fix from twenty minutes ago
/// can break up a run of consecutive readings that had confirmed a crossing,
/// and unpicking that from an accumulated counter means storing and correctly
/// restoring the engine's pending-candidate state, then getting it right again
/// every time a fence is edited.
///
/// So a touched vehicle has its crossings and trips recomputed from its fix
/// history and the rows replaced. That makes the pipeline idempotent by
/// construction rather than by argument -- the same packets in any arrival
/// order converge on the same rows, and a duplicate batch is a no-op because
/// it recomputes the same answer.
///
/// The cost is bounded and is paid per *touched* vehicle, not per fleet: a
/// packet from one truck replays one truck. tool/benchmark.dart reports what
/// that costs at 500 vehicles, and README.md records the incremental
/// checkpoint design as the thing to reach for if it ever stops being cheap.
class DerivationProcessor {
  DerivationProcessor(
    this._db, {
    this.geofenceEngine = const GeofenceEngine(),
    this.tripEngine = const TripEngine(),
  });

  final FleetDb _db;
  final GeofenceEngine geofenceEngine;
  final TripEngine tripEngine;

  Future<void> recomputeAll(Iterable<String> vehicleIds) async {
    final versions = await _loadFenceVersions();
    if (versions.isEmpty) return;
    for (final vehicleId in vehicleIds) {
      await _recompute(vehicleId, versions);
    }
  }

  Future<void> _recompute(
    String vehicleId,
    List<FenceVersion> versions,
  ) async {
    final fixes = await _loadFixes(vehicleId);

    final transitions = geofenceEngine.run(
      fixes: fixes,
      versions: versions,
      seed: {},
    );
    final trips = tripEngine.run(
      vehicleId: vehicleId,
      transitions: transitions,
    );

    await _db.transaction(() async {
      await _db.execute(
        'DELETE FROM geofence_events WHERE vehicle_id = ?',
        [vehicleId],
      );
      for (final chunk in _chunks(transitions, 200)) {
        final placeholders =
            List.filled(chunk.length, '(?, ?, ?, ?, ?, ?)').join(', ');
        await _db.execute(
          'INSERT INTO geofence_events VALUES $placeholders',
          [
            for (final t in chunk) ...[
              vehicleId,
              t.geofenceId,
              t.kind.name,
              t.eventTime,
              t.windowStart,
              t.uncertain,
            ],
          ],
        );
      }

      await _db.execute('DELETE FROM trips WHERE vehicle_id = ?', [vehicleId]);
      for (final chunk in _chunks(trips, 200)) {
        final placeholders =
            List.filled(chunk.length, '(?, ?, ?, ?, ?, ?, ?, ?, ?)').join(', ');
        await _db.execute(
          'INSERT INTO trips (trip_id, vehicle_id, origin_geofence_id, '
          'started_at, destination_geofence_id, ended_at, status, '
          'start_uncertain, end_uncertain) VALUES $placeholders',
          [
            for (final trip in chunk) ...[
              trip.tripId,
              trip.vehicleId,
              trip.originGeofenceId,
              trip.startedAt,
              trip.destinationGeofenceId,
              trip.endedAt,
              trip.inProgress ? 'in_progress' : 'completed',
              trip.startUncertain,
              trip.endUncertain,
            ],
          ],
        );
      }
    });
  }

  /// Every fence definition that has ever existed, so each fix can be judged
  /// against the one in force at its own event time.
  Future<List<FenceVersion>> _loadFenceVersions() async {
    final rows = await _db.select(
      'SELECT geofence_id, version, lat, lon, radius_m, active, '
      'valid_from, valid_to FROM geofence_versions '
      'ORDER BY geofence_id, version',
    );
    return [
      for (final row in rows)
        FenceVersion(
          geofenceId: row['geofence_id'] as String,
          version: row['version'] as int,
          lat: row['lat'] as double,
          lon: row['lon'] as double,
          radiusM: row['radius_m'] as double,
          active: row['active'] as bool,
          validFrom: row['valid_from'] as DateTime,
          validTo: row['valid_to'] as DateTime?,
        ),
    ];
  }

  /// One fix per instant, in event-time order.
  ///
  /// Two packets claiming different positions for the same moment is a real
  /// thing on a flaky link. We take the one that reached us first, which is
  /// the same tie-break current state uses, so the two never disagree.
  Future<List<Fix>> _loadFixes(String vehicleId) async {
    final rows = await _db.select('''
      SELECT event_time, ingest_time, packet_id, lat, lon, accuracy_m
      FROM (
        SELECT *, row_number() OVER (
          PARTITION BY event_time ORDER BY ingest_time, packet_id
        ) AS rn
        FROM location_fixes WHERE vehicle_id = ?
      ) WHERE rn = 1
      ORDER BY event_time
    ''', [vehicleId]);

    return [
      for (final row in rows)
        Fix(
          eventTime: row['event_time'] as DateTime,
          ingestTime: row['ingest_time'] as DateTime,
          packetId: row['packet_id'] as String,
          lat: row['lat'] as double,
          lon: row['lon'] as double,
          accuracyM: row['accuracy_m'] as double?,
        ),
    ];
  }

  Iterable<List<T>> _chunks<T>(List<T> items, int size) sync* {
    for (var i = 0; i < items.length; i += size) {
      yield items.sublist(i, (i + size).clamp(0, items.length));
    }
  }
}
