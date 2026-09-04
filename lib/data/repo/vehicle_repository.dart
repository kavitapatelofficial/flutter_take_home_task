import '../../core/clock.dart';
import '../../domain/model/models.dart';
import '../../domain/model/vehicle_status.dart';
import '../../domain/rules.dart';
import '../db/fleet_db.dart';
import 'queries.dart';

class VehicleDetail {
  const VehicleDetail({
    required this.vehicleId,
    required this.regNo,
    required this.model,
    required this.status,
    required this.readings,
    required this.lastPing,
    required this.lastPingAge,
    this.currentGeofenceName,
  });

  final String vehicleId;
  final String regNo;
  final String model;
  final VehicleStatus status;
  final List<SignalReading> readings;
  final DateTime? lastPing;
  final Duration? lastPingAge;
  final String? currentGeofenceName;
}

class VehicleRepository {
  VehicleRepository(this._db, this._clock);

  final FleetDb _db;
  final Clock _clock;

  /// The readings register.
  ///
  /// Every row carries its own age, because per-signal staleness is the point:
  /// a truck can be reporting SOC every minute while its odometer has not been
  /// mentioned in an hour, and a single vehicle-level "last seen" would hide
  /// that.
  ///
  /// A signal that has never reported is [ReadingVerdict.missing] and renders
  /// as a dash. A signal too old to judge is [ReadingVerdict.stale] and makes
  /// no normal/alert claim at all -- not a quiet NORMAL, which would be a
  /// claim we cannot support.
  Future<VehicleDetail?> detail(String vehicleId) async {
    final now = _clock.nowUtc();

    final head = await _db.selectOne(
      Q.at('SELECT * FROM (${Q.fleetRows}) WHERE vehicle_id = ?', now),
      [vehicleId],
    );
    if (head == null) return null;

    final rows = await _db.select(
      'SELECT signal, value, event_time FROM latest_readings '
      'WHERE vehicle_id = ?',
      [vehicleId],
    );
    final latest = {
      for (final row in rows)
        row['signal'] as String: (
          value: row['value'] as double,
          at: row['event_time'] as DateTime,
        ),
    };

    final readings = [
      for (final signal in [...Signals.registerOrder, Signals.ignition])
        _reading(signal, latest[signal], now),
    ];

    final lastPing = head['last_ping'] as DateTime?;

    final fence = await _db.selectOne('''
      SELECT name FROM (${Q.currentGeofence})
      WHERE vehicle_id = ? AND rank = 1
    ''', [vehicleId]);

    return VehicleDetail(
      vehicleId: vehicleId,
      regNo: head['reg_no'] as String,
      model: head['model'] as String,
      status: VehicleStatus.fromSql(head['status'] as String),
      readings: readings,
      lastPing: lastPing,
      lastPingAge: lastPing == null ? null : _age(now, lastPing),
      currentGeofenceName: fence?['name'] as String?,
    );
  }

  SignalReading _reading(
    String signal,
    ({double value, DateTime at})? latest,
    DateTime now,
  ) {
    if (latest == null) {
      return SignalReading(
        signal: signal,
        value: null,
        eventTime: null,
        age: null,
        verdict: ReadingVerdict.missing,
      );
    }

    final age = _age(now, latest.at);
    final verdict = age > Rules.signalStaleAfter
        ? ReadingVerdict.stale
        : _breaches(signal, latest.value)
            ? ReadingVerdict.alert
            : ReadingVerdict.normal;

    return SignalReading(
      signal: signal,
      value: latest.value,
      eventTime: latest.at,
      age: age,
      verdict: verdict,
    );
  }

  /// Only the signals that have a threshold can be ALERT. Speed, odometer and
  /// range have no "bad" value on their own -- a stationary truck is not a
  /// fault -- so when fresh they are simply NORMAL.
  bool _breaches(String signal, double value) => switch (signal) {
        Signals.soc => value < Rules.socWarningBelow,
        Signals.batteryTemp => value > Rules.batteryTempCriticalAbove,
        _ => false,
      };

  /// Clamped at zero so a vehicle whose clock runs a little fast reads as
  /// brand new rather than negative.
  Duration _age(DateTime now, DateTime then) {
    final delta = now.difference(then);
    return delta.isNegative ? Duration.zero : delta;
  }

  /// SOC over the retained window.
  ///
  /// Reads raw readings and rolled-up buckets together, so the chart keeps
  /// working across the retention boundary: recent history is every reading,
  /// older history is one point per bucket. The join is a UNION rather than a
  /// fallback because a window can straddle the boundary.
  Future<List<HistoryPoint>> socHistory(
    String vehicleId, {
    Duration window = const Duration(hours: 24),
    int maxPoints = 240,
  }) async {
    final now = _clock.nowUtc();
    final from = now.subtract(window);

    // Bucket width chosen so a full window lands near maxPoints. A sparkline
    // 300 pixels wide gains nothing from 5000 points and costs a lot to
    // marshal across the isolate boundary. Interpolated rather than bound
    // because DuckDB will not take a parameter inside an interval constructor.
    final bucketSeconds = (window.inSeconds / maxPoints).ceil();

    final rows = await _db.select('''
      WITH points AS (
        SELECT event_time, value
        FROM signal_readings
        WHERE vehicle_id = ? AND signal = '${Signals.soc}' AND event_time >= ?
        UNION ALL
        SELECT bucket_start AS event_time, last_value AS value
        FROM signal_rollups
        WHERE vehicle_id = ? AND signal = '${Signals.soc}'
          AND bucket_start >= ?
      ),
      bucketed AS (
        SELECT
          time_bucket(INTERVAL $bucketSeconds SECOND, event_time) AS bucket,
          arg_max(value, event_time) AS value,
          max(event_time) AS bucket_at
        FROM points
        GROUP BY bucket
      )
      SELECT bucket_at, value FROM bucketed ORDER BY bucket_at
    ''', [vehicleId, from, vehicleId, from]);

    return [
      for (final row in rows)
        HistoryPoint(row['bucket_at'] as DateTime, row['value'] as double),
    ];
  }

  /// The raw tail, for the history table under the chart. Shows that what is
  /// on screen came out of an event log.
  Future<List<HistoryPoint>> recentSocReadings(
    String vehicleId, {
    int limit = 50,
  }) async {
    final rows = await _db.select('''
      SELECT event_time, value FROM signal_readings
      WHERE vehicle_id = ? AND signal = '${Signals.soc}'
      ORDER BY event_time DESC LIMIT ?
    ''', [vehicleId, limit]);
    return [
      for (final row in rows)
        HistoryPoint(row['event_time'] as DateTime, row['value'] as double),
    ];
  }
}
