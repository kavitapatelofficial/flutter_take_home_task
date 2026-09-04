import '../../core/clock.dart';
import '../../domain/rules.dart';
import '../db/fleet_db.dart';

/// Opens, escalates and resolves alerts.
///
/// Runs after every ingest, against current state rather than against the
/// incoming batch, so it cannot be fooled by a late packet: a reading that did
/// not become current does not raise an alert about a battery level the truck
/// left behind an hour ago.
///
/// Three lifecycle rules, all of which the spec asks for and none of which are
/// obvious from the threshold table alone:
///
/// **The two SOC thresholds are one alert.** Severity is a column on the open
/// instance, recomputed on every fresh reading. A truck sliding 21 -> 18 -> 9
/// raises exactly one alert that escalates to critical; charging back to 15
/// de-escalates the same alert rather than resolving it and raising a second.
/// The alert only ends when SOC clears 20 altogether.
///
/// **Resolution and dismissal are independent.** Dismissing annotates the
/// instance; it does not close it. A condition clearing closes the instance
/// whether or not anyone dismissed it. The consequence that matters to an
/// operator: dismissing "low battery" on a truck today does not suppress
/// tomorrow's, because tomorrow's is a *new instance* -- the old one was
/// closed when the truck charged overnight, and a new instance starts
/// undismissed.
///
/// **Staleness suspends rather than resolves.** If the driving signal stops
/// reporting we make no claim in either direction, exactly as the readings
/// register does. The alert is hidden from the active list but the row stays
/// open, so when the truck comes back on air we do not raise a duplicate
/// alongside the one we already had.
class AlertProcessor {
  AlertProcessor(this._db, this._clock);

  final FleetDb _db;
  final Clock _clock;

  /// Re-evaluates every alert condition for the given vehicles.
  ///
  /// Pass null to sweep the whole fleet, which is what the periodic refresh
  /// does so that conditions can be re-checked as readings age.
  Future<void> evaluate({Iterable<String>? vehicleIds}) async {
    final now = _clock.nowUtc();
    final staleSeconds = Rules.signalStaleAfter.inSeconds;

    final scope = vehicleIds == null
        ? ''
        : 'AND vehicle_id IN (${_quotedList(vehicleIds)})';
    if (vehicleIds != null && vehicleIds.isEmpty) return;

    await _db.transaction(() async {
      // One row per (vehicle, condition) that we are currently entitled to
      // judge. A signal outside the staleness window simply does not appear,
      // which is how "no claim" is expressed.
      await _db.execute('''
        CREATE OR REPLACE TEMP TABLE alert_eval AS
        SELECT vehicle_id,
               'battery_soc' AS kind,
               value AS trigger_value,
               event_time,
               value < ${Rules.socWarningBelow} AS breached,
               CASE WHEN value < ${Rules.socCriticalBelow}
                    THEN 'critical' ELSE 'warning' END AS severity
        FROM latest_readings
        WHERE signal = '${Signals.soc}'
          AND ${RuleSql.ageSeconds('event_time', '?')} <= $staleSeconds
          $scope
        UNION ALL
        SELECT vehicle_id,
               'battery_temp',
               value,
               event_time,
               value > ${Rules.batteryTempCriticalAbove},
               'critical'
        FROM latest_readings
        WHERE signal = '${Signals.batteryTemp}'
          AND ${RuleSql.ageSeconds('event_time', '?')} <= $staleSeconds
          $scope
      ''', [now, now]);

      // A fresh reading showing the condition gone closes the instance. We
      // date the resolution at the reading's event time, not at wall clock,
      // so the history reads in the vehicle's terms.
      await _db.execute('''
        UPDATE alerts SET resolved_at = e.event_time
        FROM alert_eval e
        WHERE alerts.vehicle_id = e.vehicle_id
          AND alerts.kind = e.kind
          AND alerts.resolved_at IS NULL
          AND NOT e.breached
      ''');

      // Escalate or de-escalate an instance that is still breached. The
      // event-time guard keeps a stale re-evaluation from walking the
      // severity backwards.
      await _db.execute('''
        UPDATE alerts
        SET severity = e.severity,
            trigger_value = e.trigger_value,
            last_seen_at = e.event_time
        FROM alert_eval e
        WHERE alerts.vehicle_id = e.vehicle_id
          AND alerts.kind = e.kind
          AND alerts.resolved_at IS NULL
          AND e.breached
          AND e.event_time >= alerts.last_seen_at
      ''');

      // Open an instance where the condition is breached and nothing is
      // already open for it.
      await _db.execute('''
        INSERT INTO alerts (
          alert_id, vehicle_id, kind, severity, trigger_value,
          opened_at, last_seen_at, resolved_at, dismissed_at, dismiss_reason
        )
        SELECT md5(e.vehicle_id || e.kind || CAST(e.event_time AS VARCHAR)),
               e.vehicle_id, e.kind, e.severity, e.trigger_value,
               e.event_time, e.event_time, NULL, NULL, NULL
        FROM alert_eval e
        WHERE e.breached
          AND NOT EXISTS (
            SELECT 1 FROM alerts a
            WHERE a.vehicle_id = e.vehicle_id
              AND a.kind = e.kind
              AND a.resolved_at IS NULL
          )
        ON CONFLICT DO NOTHING
      ''');
    });
  }

  /// Removes an alert from the operator's list without closing it.
  Future<void> dismiss(String alertId, String reason) => _db.execute(
        'UPDATE alerts SET dismissed_at = ?, dismiss_reason = ? '
        'WHERE alert_id = ?',
        [_clock.nowUtc(), reason, alertId],
      );

  /// Puts it straight back. Backs the five-second UNDO window.
  Future<void> undoDismiss(String alertId) => _db.execute(
        'UPDATE alerts SET dismissed_at = NULL, dismiss_reason = NULL '
        'WHERE alert_id = ?',
        [alertId],
      );

  String _quotedList(Iterable<String> values) =>
      values.map((v) => "'${v.replaceAll("'", "''")}'").join(', ');
}
