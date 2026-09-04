import '../../domain/rules.dart';

/// SQL fragments shared by the read repositories.
///
/// These are here rather than inline so that the freshness rules and the
/// status ladder exist exactly once. The fleet list, the filter counts and the
/// vehicle detail screen all have to agree about what OFFLINE means, and the
/// cheapest way to guarantee that is to give them one string to agree on.
///
/// The current time appears a dozen times in some of these -- once per
/// freshness test -- and is written as the token `$now`, which [Q.at]
/// substitutes for a literal.
///
/// Binding it would be tidier, but dart_duckdb enumerates named parameters by
/// scanning the SQL text and does not collapse repeats, so a parameter used
/// six times gets six slots while DuckDB itself allocates one, and every
/// binding after the first lands on the wrong index. A timestamp we generated
/// ourselves carries no injection risk, so a literal is the safe way out. Real
/// user input (a search box, an id) still goes through bound parameters.
///
/// It comes from the injectable clock rather than the database's own now(), so
/// tests drive staleness by moving a fixed clock instead of sleeping.
class Q {
  const Q._();

  /// Substitutes the clock into a fragment.
  static String at(String sql, DateTime now) =>
      sql.replaceAll(r'$now', sqlTimestamp(now));

  static final _offline = Rules.vehicleOfflineAfter.inSeconds;
  static final _stale = Rules.signalStaleAfter.inSeconds;

  /// Current value and age of every signal we care about, one row per vehicle.
  ///
  /// Reads the projection, not the log: this is 500 vehicles times a handful
  /// of signals however much history is behind it.
  static final latestPerVehicle = '''
    SELECT
      vehicle_id,
      max(value)      FILTER (WHERE signal = '${Signals.soc}')          AS soc,
      max(event_time) FILTER (WHERE signal = '${Signals.soc}')          AS soc_at,
      max(value)      FILTER (WHERE signal = '${Signals.rangeKm}')      AS range_km,
      max(event_time) FILTER (WHERE signal = '${Signals.rangeKm}')      AS range_at,
      max(value)      FILTER (WHERE signal = '${Signals.speed}')        AS speed,
      max(event_time) FILTER (WHERE signal = '${Signals.speed}')        AS speed_at,
      max(value)      FILTER (WHERE signal = '${Signals.ignition}')     AS ignition,
      max(event_time) FILTER (WHERE signal = '${Signals.ignition}')     AS ignition_at,
      max(value)      FILTER (WHERE signal = '${Signals.batteryTemp}')  AS battery_temp,
      max(event_time) FILTER (WHERE signal = '${Signals.batteryTemp}')  AS battery_temp_at,
      max(event_time)                                                   AS last_ping
    FROM latest_readings
    GROUP BY vehicle_id
  ''';

  /// The status ladder, first match wins.
  ///
  /// The mirror of classifyStatus() in domain/model/vehicle_status.dart; a
  /// test runs the same table of cases through both to keep them honest.
  ///
  /// The final ELSE is the judgement call: a vehicle that is online but has
  /// gone quiet on both speed and ignition reads as STOPPED. See the note on
  /// classifyStatus for why that beats a fifth chip or calling it offline.
  static final statusExpression = '''
    CASE
      WHEN l.last_ping IS NULL
        OR ${RuleSql.ageSeconds('l.last_ping', r'$now')} > $_offline
        THEN 'offline'
      WHEN l.speed IS NOT NULL
        AND ${RuleSql.ageSeconds('l.speed_at', r'$now')} <= $_stale
        AND l.speed > 0
        THEN 'moving'
      WHEN l.speed IS NOT NULL
        AND ${RuleSql.ageSeconds('l.speed_at', r'$now')} <= $_stale
        AND l.speed = 0
        AND l.ignition IS NOT NULL
        AND ${RuleSql.ageSeconds('l.ignition_at', r'$now')} <= $_stale
        AND l.ignition = 1
        THEN 'idle'
      ELSE 'stopped'
    END
  ''';

  /// Alerts an operator should currently be looking at.
  ///
  /// Three conditions, each one a rule from the spec:
  ///   resolved_at IS NULL   -- the condition has not cleared
  ///   dismissed_at IS NULL  -- nobody has waved it away
  ///   and the driving signal is fresh
  ///
  /// That last one is why this is a join rather than a WHERE on the alerts
  /// table alone. An alert whose signal has gone stale makes no claim, exactly
  /// as the readings register makes no claim: we hide it without resolving it,
  /// so that when the truck comes back on air we still have the instance we
  /// opened rather than raising a second one beside it.
  static final visibleAlerts = '''
    SELECT a.*
    FROM alerts a
    JOIN latest_readings lr
      ON lr.vehicle_id = a.vehicle_id
     AND lr.signal = CASE a.kind
           WHEN 'battery_soc'  THEN '${Signals.soc}'
           WHEN 'battery_temp' THEN '${Signals.batteryTemp}'
         END
    WHERE a.resolved_at IS NULL
      AND a.dismissed_at IS NULL
      AND ${RuleSql.ageSeconds('lr.event_time', r'$now')} <= $_stale
  ''';

  /// Per-vehicle alert rollup for the fleet list badge.
  static final alertRollup = '''
    SELECT vehicle_id,
           count(*) AS open_alerts,
           max(CASE WHEN severity = 'critical' THEN 2 ELSE 1 END) AS worst_rank
    FROM ($visibleAlerts)
    GROUP BY vehicle_id
  ''';

  /// The fleet list, one row per vehicle, everything already decided.
  static final fleetRows = '''
    SELECT
      v.vehicle_id,
      v.reg_no,
      v.model,
      l.soc,
      l.range_km,
      l.last_ping,
      $statusExpression AS status,
      coalesce(r.open_alerts, 0) AS open_alerts,
      r.worst_rank
    FROM vehicles v
    LEFT JOIN ($latestPerVehicle) l ON l.vehicle_id = v.vehicle_id
    LEFT JOIN ($alertRollup)      r ON r.vehicle_id = v.vehicle_id
  ''';

  /// Where a vehicle is right now.
  ///
  /// A vehicle can sit inside several overlapping fences at once, so "current
  /// geofence" needs a tie-break. We take the smallest active fence
  /// containing the last fix -- the most specific answer is the useful one,
  /// since "Depot 3, bay area" tells an operator more than "Bengaluru". Ties
  /// on radius break on id so the answer never flickers.
  ///
  /// This reads the last fix directly rather than the crossing log, because
  /// the crossing log deliberately says nothing until a change is confirmed,
  /// and "where is it" should not lag behind by a confirmation.
  static final currentGeofence = r'''
    WITH last_fix AS (
      SELECT vehicle_id, lat, lon, event_time
      FROM (
        SELECT *, row_number() OVER (
          PARTITION BY vehicle_id ORDER BY event_time DESC, ingest_time DESC
        ) AS rn
        FROM location_fixes
      ) WHERE rn = 1
    )
    SELECT f.vehicle_id, g.geofence_id, g.name, g.radius_m,
           row_number() OVER (
             PARTITION BY f.vehicle_id ORDER BY g.radius_m, g.geofence_id
           ) AS rank
    FROM last_fix f
    JOIN geofences_current g
      ON g.active
     AND 2 * 6371008.8 * asin(sqrt(
           pow(sin(radians(g.lat - f.lat) / 2), 2) +
           cos(radians(f.lat)) * cos(radians(g.lat)) *
           pow(sin(radians(g.lon - f.lon) / 2), 2)
         )) <= g.radius_m
  ''';
}

/// A DateTime as a DuckDB TIMESTAMP literal, in UTC and to the microsecond.
String sqlTimestamp(DateTime value) {
  final t = value.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final micros = (t.millisecond * 1000 + t.microsecond)
      .toString()
      .padLeft(6, '0');
  return "TIMESTAMP '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-"
      "${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}.$micros'";
}
