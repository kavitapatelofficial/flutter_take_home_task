import '../../core/clock.dart';
import '../../domain/model/models.dart';
import '../db/fleet_db.dart';
import 'queries.dart';

class AlertRepository {
  AlertRepository(this._db, this._clock);

  final FleetDb _db;
  final Clock _clock;

  /// Alerts an operator should act on: unresolved, undismissed, and with a
  /// signal fresh enough to still be making the claim.
  Future<List<FleetAlert>> active({String? vehicleId}) async {
    final params = <Object?>[];
    var filter = '';
    if (vehicleId != null) {
      filter = 'WHERE a.vehicle_id = ?';
      params.add(vehicleId);
    }

    final rows = await _db.select(Q.at('''
      SELECT a.*, v.reg_no
      FROM (${Q.visibleAlerts}) a
      JOIN vehicles v USING (vehicle_id)
      $filter
      ORDER BY
        CASE a.severity WHEN 'critical' THEN 0 ELSE 1 END,
        a.opened_at DESC
    ''', _clock.nowUtc()), params);

    return [
      for (final row in rows)
        FleetAlert(
          alertId: row['alert_id'] as String,
          vehicleId: row['vehicle_id'] as String,
          regNo: row['reg_no'] as String,
          kind: AlertKind.fromSql(row['kind'] as String),
          severity: AlertSeverity.fromSql(row['severity'] as String),
          openedAt: row['opened_at'] as DateTime,
          lastSeenAt: row['last_seen_at'] as DateTime,
          triggerValue: row['trigger_value'] as double,
        ),
    ];
  }

  Future<int> activeCount() async {
    final row = await _db.selectOne(
      Q.at('SELECT count(*) AS n FROM (${Q.visibleAlerts}) a', _clock.nowUtc()),
    );
    return row!['n'] as int;
  }

  /// Alerts an operator waved away that are still technically open. Useful for
  /// showing that dismissal hid something rather than fixed it.
  Future<int> dismissedCount() async {
    final row = await _db.selectOne(
      'SELECT count(*) AS n FROM alerts '
      'WHERE resolved_at IS NULL AND dismissed_at IS NOT NULL',
    );
    return row!['n'] as int;
  }
}
