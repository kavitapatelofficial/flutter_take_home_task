import '../../core/clock.dart';
import '../../core/ids.dart';
import '../../domain/model/models.dart';
import '../db/fleet_db.dart';
import 'queries.dart';

/// Geofence CRUD, versioned.
///
/// Nothing here updates a fence's geometry in place. Every edit closes the
/// current version and opens a new one, because the crossing engine judges
/// each fix against the definition in force at that fix's own event time. If
/// an operator widens the depot fence this afternoon, this morning's
/// departures must still read against this morning's fence -- a truck that
/// genuinely left did not un-leave because someone moved a circle.
///
/// Deactivation is the same mechanism: a new version with active = false. The
/// fence stops producing crossings from that moment, and every crossing and
/// trip it produced while it was live stays readable, which is what "retain
/// deactivated geofences for trip history" needs.
class GeofenceRepository {
  GeofenceRepository(this._db, this._clock);

  final FleetDb _db;
  final Clock _clock;

  /// Current definitions, with a live count of the vehicles inside each.
  ///
  /// The count is containment, not exclusive assignment: a truck inside both
  /// the depot and the city fence counts for both. That is the honest answer
  /// to "how many vehicles are in this fence" -- the exclusive, most-specific
  /// answer is what the vehicle's own "current geofence" field shows, and the
  /// two questions are different.
  Future<List<Geofence>> list({bool includeInactive = true}) async {
    final rows = await _db.select('''
      WITH inside AS (
        SELECT geofence_id, count(*) AS n
        FROM (${Q.currentGeofence})
        GROUP BY geofence_id
      )
      SELECT g.*, coalesce(inside.n, 0) AS vehicle_count
      FROM geofences_current g
      LEFT JOIN inside USING (geofence_id)
      ${includeInactive ? '' : 'WHERE g.active'}
      ORDER BY g.active DESC, g.name
    ''');

    return [
      for (final row in rows)
        Geofence(
          geofenceId: row['geofence_id'] as String,
          version: row['version'] as int,
          name: row['name'] as String,
          lat: row['lat'] as double,
          lon: row['lon'] as double,
          radiusM: row['radius_m'] as double,
          active: row['active'] as bool,
          validFrom: row['valid_from'] as DateTime,
          vehicleCount: row['vehicle_count'] as int,
        ),
    ];
  }

  Future<String> create({
    required String name,
    required double lat,
    required double lon,
    required double radiusM,
    DateTime? validFrom,
  }) async {
    final id = stableId(['fence', name, lat, lon, _clock.nowUtc()]);
    final from = validFrom ?? _clock.nowUtc();

    await _db.transaction(() async {
      await _db.execute('INSERT INTO geofences VALUES (?, ?)', [id, from]);
      await _db.execute(
        'INSERT INTO geofence_versions VALUES (?, 1, ?, ?, ?, ?, TRUE, ?, NULL)',
        [id, name, lat, lon, radiusM, from],
      );
    });
    return id;
  }

  /// Supersedes the current version. Fields left null keep their value.
  Future<void> edit(
    String geofenceId, {
    String? name,
    double? lat,
    double? lon,
    double? radiusM,
    bool? active,
  }) async {
    final at = _clock.nowUtc();

    await _db.transaction(() async {
      final current = await _db.selectOne(
        'SELECT * FROM geofence_versions '
        'WHERE geofence_id = ? AND valid_to IS NULL',
        [geofenceId],
      );
      if (current == null) return;

      final version = (current['version'] as int) + 1;

      // A version that would have zero width in event time is not a version.
      // Two edits inside the same clock tick collapse onto one row rather
      // than leaving a definition that was never in force -- which would
      // otherwise be a hole the crossing engine could fall into.
      if (!(current['valid_from'] as DateTime).isBefore(at)) {
        await _db.execute('''
          UPDATE geofence_versions
          SET name = ?, lat = ?, lon = ?, radius_m = ?, active = ?
          WHERE geofence_id = ? AND valid_to IS NULL
        ''', [
          name ?? current['name'],
          lat ?? current['lat'],
          lon ?? current['lon'],
          radiusM ?? current['radius_m'],
          active ?? current['active'],
          geofenceId,
        ]);
        return;
      }

      await _db.execute(
        'UPDATE geofence_versions SET valid_to = ? '
        'WHERE geofence_id = ? AND valid_to IS NULL',
        [at, geofenceId],
      );
      await _db.execute(
        'INSERT INTO geofence_versions VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)',
        [
          geofenceId,
          version,
          name ?? current['name'],
          lat ?? current['lat'],
          lon ?? current['lon'],
          radiusM ?? current['radius_m'],
          active ?? current['active'],
          at,
        ],
      );
    });
  }

  Future<void> setActive(String geofenceId, {required bool active}) =>
      edit(geofenceId, active: active);

  /// Every version ever, for the crossing engine.
  Future<List<Map<String, Object?>>> allVersions() => _db.select(
        'SELECT * FROM geofence_versions ORDER BY geofence_id, version',
      );
}
