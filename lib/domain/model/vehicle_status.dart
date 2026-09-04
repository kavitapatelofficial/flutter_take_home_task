import '../rules.dart';

/// The fleet-list status chip. Order matters: first match wins, as specified.
enum VehicleStatus {
  offline('OFFLINE'),
  moving('MOVING'),
  idle('IDLE'),
  stopped('STOPPED');

  const VehicleStatus(this.label);

  final String label;

  static VehicleStatus fromSql(String value) =>
      VehicleStatus.values.firstWhere((s) => s.name == value);
}

/// Classifies a vehicle from its latest readings.
///
/// This mirrors the CASE expression in [FleetQueries.statusExpression]. It
/// exists so the rule can be unit-tested against a table of cases without
/// standing up a database, and so the two implementations can be checked
/// against each other (see test/domain/vehicle_status_test.dart, which runs
/// the same cases through both).
///
/// The judgement calls, in order:
///
/// 1. OFFLINE is decided on the *vehicle* clock -- the newest event time of
///    any signal. If we have not heard from the truck at all in ten minutes,
///    nothing else it previously said is worth chipping.
///
/// 2. MOVING/IDLE/STOPPED are decided on *fresh* speed and ignition only. A
///    speed of 60 km/h reported nine minutes ago and never since does not mean
///    the vehicle is moving now; it means we have a heartbeat from some other
///    signal and no current motion data.
///
/// 3. If a vehicle is online but neither speed nor ignition is fresh, it falls
///    through to STOPPED. This is the one place the spec's four buckets do not
///    cover the data, and there were three options: invent a fifth UNKNOWN
///    chip, count it as OFFLINE, or pick a resting default. A fifth chip
///    breaks the specified filter set, and OFFLINE is a lie -- the vehicle is
///    demonstrably talking to us. STOPPED is the conservative claim: we never
///    assert motion we cannot see, and an operator scanning for problems is
///    not sent chasing a truck that is merely quiet on one signal. The
///    readings register on the detail screen shows the real per-signal
///    staleness, so the information is not lost, only summarised.
VehicleStatus classifyStatus({
  required Duration? sinceLastPing,
  required double? speed,
  required Duration? speedAge,
  required bool? ignitionOn,
  required Duration? ignitionAge,
}) {
  if (sinceLastPing == null || sinceLastPing > Rules.vehicleOfflineAfter) {
    return VehicleStatus.offline;
  }

  final speedFresh =
      speed != null && speedAge != null && speedAge <= Rules.signalStaleAfter;
  final ignitionFresh = ignitionOn != null &&
      ignitionAge != null &&
      ignitionAge <= Rules.signalStaleAfter;

  if (speedFresh && speed > 0) return VehicleStatus.moving;
  if (speedFresh && speed == 0 && ignitionFresh && ignitionOn) {
    return VehicleStatus.idle;
  }
  if (ignitionFresh && !ignitionOn) return VehicleStatus.stopped;

  return VehicleStatus.stopped;
}
