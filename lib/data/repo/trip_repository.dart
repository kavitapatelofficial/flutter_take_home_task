import '../../domain/model/models.dart';
import '../db/fleet_db.dart';

class TripRepository {
  TripRepository(this._db);

  final FleetDb _db;

  /// Trips for a vehicle, newest first.
  ///
  /// Fence names are joined from `geofence_versions` rather than from the
  /// current definitions, so a trip that ended at a depot which has since been
  /// deactivated still says where it went instead of showing a bare id. That
  /// is the point of keeping retired fences.
  Future<List<Trip>> forVehicle(String vehicleId, {int limit = 50}) async {
    final rows = await _db.select('''
      WITH names AS (
        SELECT geofence_id, arg_max(name, version) AS name
        FROM geofence_versions GROUP BY geofence_id
      )
      SELECT t.*, o.name AS origin_name, d.name AS destination_name
      FROM trips t
      LEFT JOIN names o ON o.geofence_id = t.origin_geofence_id
      LEFT JOIN names d ON d.geofence_id = t.destination_geofence_id
      WHERE t.vehicle_id = ?
      ORDER BY t.started_at DESC
      LIMIT ?
    ''', [vehicleId, limit]);

    return [
      for (final row in rows)
        Trip(
          tripId: row['trip_id'] as String,
          vehicleId: row['vehicle_id'] as String,
          originGeofenceId: row['origin_geofence_id'] as String?,
          originName: row['origin_name'] as String?,
          startedAt: row['started_at'] as DateTime,
          status: TripStatus.fromSql(row['status'] as String),
          destinationGeofenceId: row['destination_geofence_id'] as String?,
          destinationName: row['destination_name'] as String?,
          endedAt: row['ended_at'] as DateTime?,
          startUncertain: row['start_uncertain'] as bool,
          endUncertain: row['end_uncertain'] as bool,
        ),
    ];
  }

  Future<int> inProgressCount() async {
    final row = await _db.selectOne(
      "SELECT count(*) AS n FROM trips WHERE status = 'in_progress'",
    );
    return row!['n'] as int;
  }
}
