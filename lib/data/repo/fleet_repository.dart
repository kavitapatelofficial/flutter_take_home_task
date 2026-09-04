import '../../core/clock.dart';
import '../../domain/model/models.dart';
import '../../domain/model/vehicle_status.dart';
import '../db/fleet_db.dart';
import 'queries.dart';

/// Reads for the fleet home screen.
///
/// Both the list and the chip counts are one query each. Pulling 500 rows into
/// Dart and classifying them there would work at this size and stop working at
/// the next one, and it would put the status ladder in two places.
class FleetRepository {
  FleetRepository(this._db, this._clock);

  final FleetDb _db;
  final Clock _clock;

  Future<List<FleetVehicle>> list({
    VehicleStatus? status,
    String query = '',
  }) async {
    final filters = <String>[];
    final params = <Object?>[];

    if (status != null) {
      filters.add('status = ?');
      params.add(status.name);
    }
    if (query.trim().isNotEmpty) {
      filters.add('(reg_no ILIKE ? OR model ILIKE ?)');
      params..add('%${query.trim()}%')..add('%${query.trim()}%');
    }

    final where = filters.isEmpty ? '' : 'WHERE ${filters.join(' AND ')}';

    final rows = await _db.select(Q.at('''
      SELECT * FROM (${Q.fleetRows})
      $where
      ORDER BY
        -- Anything with a critical alert floats to the top, then anything
        -- with any alert. The screen has to answer "what needs attention
        -- now", and alphabetical order answers a different question.
        coalesce(worst_rank, 0) DESC,
        open_alerts DESC,
        reg_no
    ''', _clock.nowUtc()), params);

    return [for (final row in rows) _toVehicle(row)];
  }

  /// Live counts for the filter chips, computed in SQL over the same
  /// definition the list uses.
  Future<FleetCounts> counts({String query = ''}) async {
    final params = <Object?>[];
    var where = '';
    if (query.trim().isNotEmpty) {
      where = 'WHERE reg_no ILIKE ? OR model ILIKE ?';
      params..add('%${query.trim()}%')..add('%${query.trim()}%');
    }

    final rows = await _db.select(Q.at('''
      SELECT status, count(*) AS n FROM (${Q.fleetRows})
      $where
      GROUP BY status
    ''', _clock.nowUtc()), params);

    final byStatus = <VehicleStatus, int>{
      for (final status in VehicleStatus.values) status: 0,
    };
    for (final row in rows) {
      byStatus[VehicleStatus.fromSql(row['status'] as String)] =
          row['n'] as int;
    }
    return FleetCounts(byStatus);
  }

  FleetVehicle _toVehicle(Map<String, Object?> row) {
    final worst = row['worst_rank'] as int?;
    return FleetVehicle(
      vehicleId: row['vehicle_id'] as String,
      regNo: row['reg_no'] as String,
      model: row['model'] as String,
      status: VehicleStatus.fromSql(row['status'] as String),
      soc: row['soc'] as double?,
      rangeKm: row['range_km'] as double?,
      lastPing: row['last_ping'] as DateTime?,
      openAlerts: row['open_alerts'] as int,
      worstSeverity: switch (worst) {
        2 => AlertSeverity.critical,
        1 => AlertSeverity.warning,
        _ => null,
      },
    );
  }
}

class FleetCounts {
  const FleetCounts(this.byStatus);

  final Map<VehicleStatus, int> byStatus;

  int get total => byStatus.values.fold(0, (a, b) => a + b);

  int operator [](VehicleStatus status) => byStatus[status] ?? 0;
}
