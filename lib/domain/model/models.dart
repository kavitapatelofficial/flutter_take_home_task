import '../rules.dart';
import 'vehicle_status.dart';

/// A row of the fleet list. Everything on it is computed in SQL.
class FleetVehicle {
  const FleetVehicle({
    required this.vehicleId,
    required this.regNo,
    required this.model,
    required this.status,
    required this.soc,
    required this.rangeKm,
    required this.lastPing,
    required this.openAlerts,
    required this.worstSeverity,
  });

  final String vehicleId;
  final String regNo;
  final String model;
  final VehicleStatus status;
  final double? soc;
  final double? rangeKm;
  final DateTime? lastPing;
  final int openAlerts;
  final AlertSeverity? worstSeverity;
}

/// The verdict pill in the readings register.
enum ReadingVerdict {
  /// Fresh and inside its threshold.
  normal,

  /// Fresh and outside its threshold.
  alert,

  /// Too old to judge. Deliberately makes no normal/alert claim.
  stale,

  /// Never reported. Rendered as a dash with no pill at all.
  missing,
}

class SignalReading {
  const SignalReading({
    required this.signal,
    required this.value,
    required this.eventTime,
    required this.age,
    required this.verdict,
  });

  final String signal;
  final double? value;
  final DateTime? eventTime;
  final Duration? age;
  final ReadingVerdict verdict;

  String get label => Signals.labels[signal] ?? signal;
  String get unit => Signals.units[signal] ?? '';
}

enum AlertSeverity {
  warning('Warning'),
  critical('Critical');

  const AlertSeverity(this.label);

  final String label;

  static AlertSeverity fromSql(String v) =>
      AlertSeverity.values.firstWhere((s) => s.name == v);
}

/// Alert kinds.
///
/// Note that the two SOC thresholds share one kind. The spec is explicit that
/// low battery and critically low battery are one escalating alert, not two,
/// so severity is a property of the open alert instance and is recomputed on
/// every fresh reading -- a truck that drops 21% -> 18% -> 9% raises exactly
/// one alert that escalates, and charging back to 15% de-escalates the same
/// alert rather than resolving and re-raising it.
enum AlertKind {
  batterySoc('battery_soc', 'Battery'),
  batteryTemp('battery_temp', 'Battery overheating');

  const AlertKind(this.sql, this.label);

  final String sql;
  final String label;

  static AlertKind fromSql(String v) =>
      AlertKind.values.firstWhere((k) => k.sql == v);
}

class FleetAlert {
  const FleetAlert({
    required this.alertId,
    required this.vehicleId,
    required this.regNo,
    required this.kind,
    required this.severity,
    required this.openedAt,
    required this.lastSeenAt,
    required this.triggerValue,
  });

  final String alertId;
  final String vehicleId;
  final String regNo;
  final AlertKind kind;
  final AlertSeverity severity;
  final DateTime openedAt;
  final DateTime lastSeenAt;
  final double triggerValue;

  /// The headline the operator reads. Severity is part of the sentence
  /// because the two SOC bands share a kind.
  String get title {
    switch (kind) {
      case AlertKind.batterySoc:
        return severity == AlertSeverity.critical
            ? 'Battery critically low'
            : 'Low battery';
      case AlertKind.batteryTemp:
        return 'Battery overheating';
    }
  }

  String get detail {
    switch (kind) {
      case AlertKind.batterySoc:
        return '${triggerValue.toStringAsFixed(0)}% state of charge';
      case AlertKind.batteryTemp:
        return '${triggerValue.toStringAsFixed(1)} °C';
    }
  }
}

/// Reasons offered in the dismissal sheet, in the order the spec gives.
enum DismissReason {
  onIt('I am on it'),
  wrongAlert('Wrong alert'),
  somethingElse('Something else...');

  const DismissReason(this.label);

  final String label;

  static DismissReason fromSql(String v) =>
      DismissReason.values.firstWhere((r) => r.name == v);
}

class Geofence {
  const Geofence({
    required this.geofenceId,
    required this.version,
    required this.name,
    required this.lat,
    required this.lon,
    required this.radiusM,
    required this.active,
    required this.validFrom,
    this.vehicleCount = 0,
  });

  final String geofenceId;
  final int version;
  final String name;
  final double lat;
  final double lon;
  final double radiusM;
  final bool active;
  final DateTime validFrom;
  final int vehicleCount;
}

enum TripStatus {
  inProgress('in_progress', 'In progress'),
  completed('completed', 'Completed');

  const TripStatus(this.sql, this.label);

  final String sql;
  final String label;

  static TripStatus fromSql(String v) =>
      TripStatus.values.firstWhere((s) => s.sql == v);
}

class Trip {
  const Trip({
    required this.tripId,
    required this.vehicleId,
    required this.originGeofenceId,
    required this.originName,
    required this.startedAt,
    required this.status,
    this.destinationGeofenceId,
    this.destinationName,
    this.endedAt,
    this.startUncertain = false,
    this.endUncertain = false,
    this.distanceKm,
  });

  final String tripId;
  final String vehicleId;
  final String? originGeofenceId;
  final String? originName;
  final DateTime startedAt;
  final TripStatus status;
  final String? destinationGeofenceId;
  final String? destinationName;
  final DateTime? endedAt;
  final bool startUncertain;
  final bool endUncertain;
  final double? distanceKm;

  Duration? get duration => endedAt?.difference(startedAt);
}

/// A point on the SOC history chart.
class HistoryPoint {
  const HistoryPoint(this.at, this.value);

  final DateTime at;
  final double value;
}
