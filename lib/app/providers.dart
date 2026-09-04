import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repo/fleet_repository.dart';
import '../data/repo/vehicle_repository.dart';
import '../domain/model/models.dart';
import '../domain/model/vehicle_status.dart';
import 'services.dart';

/// Overridden at startup with the booted services.
final servicesProvider = Provider<AppServices>(
  (ref) => throw StateError('AppServices not provided'),
);

/// How often to re-query purely because time has passed.
///
/// Overridden to null in widget tests: a periodic timer means the widget tree
/// never reaches a quiescent state, so pumpAndSettle would spin forever. Tests
/// drive the pipeline directly and pump for a bounded time instead.
final refreshIntervalProvider =
    Provider<Duration?>((ref) => const Duration(seconds: 3));

/// A tick every time the screen could be out of date.
///
/// Two sources. The pipeline fires one after any write, which covers new
/// telemetry and operator actions. A timer fires one every few seconds, which
/// covers the changes that happen because time passed rather than because
/// anything was written -- a vehicle ageing into OFFLINE, a reading going
/// stale, an alert falling quiet. Without the second source a screen left open
/// would sit there insisting a truck is still moving.
final refreshTickProvider = StreamProvider<int>((ref) {
  final services = ref.watch(servicesProvider);
  final controller = StreamController<int>();
  var count = 0;

  final subscription = services.pipeline.changes.listen(
    (_) => controller.add(++count),
  );
  final interval = ref.watch(refreshIntervalProvider);
  final timer = interval == null
      ? null
      : Timer.periodic(interval, (_) => controller.add(++count));

  ref.onDispose(() {
    subscription.cancel();
    timer?.cancel();
    controller.close();
  });

  controller.add(count);
  return controller.stream;
});

/// What the fleet list is currently filtered to.
class FleetFilter {
  const FleetFilter({this.status, this.query = ''});

  final VehicleStatus? status;
  final String query;

  FleetFilter copyWith({VehicleStatus? status, String? query, bool clearStatus = false}) =>
      FleetFilter(
        status: clearStatus ? null : (status ?? this.status),
        query: query ?? this.query,
      );

  @override
  bool operator ==(Object other) =>
      other is FleetFilter && other.status == status && other.query == query;

  @override
  int get hashCode => Object.hash(status, query);
}

final fleetFilterProvider =
    StateProvider<FleetFilter>((ref) => const FleetFilter());

/// Providers below all watch the tick, so a write anywhere re-queries the
/// database rather than any screen trying to patch itself from a delta. The
/// database is the source of truth; a widget holding a divergent copy of it is
/// exactly the bug this architecture exists to prevent.
///
/// Riverpod keeps the previous value visible while a refresh is in flight, so
/// re-querying on a three second tick does not flash a spinner over a list
/// that is already on screen.

final fleetListProvider = FutureProvider<List<FleetVehicle>>((ref) async {
  ref.watch(refreshTickProvider);
  final filter = ref.watch(fleetFilterProvider);
  return ref
      .watch(servicesProvider)
      .fleet
      .list(status: filter.status, query: filter.query);
});

final fleetCountsProvider = FutureProvider<FleetCounts>((ref) async {
  ref.watch(refreshTickProvider);
  final filter = ref.watch(fleetFilterProvider);
  return ref.watch(servicesProvider).fleet.counts(query: filter.query);
});

final activeAlertsProvider = FutureProvider<List<FleetAlert>>((ref) async {
  ref.watch(refreshTickProvider);
  return ref.watch(servicesProvider).alerts.active();
});

final alertCountProvider = FutureProvider<int>((ref) async {
  ref.watch(refreshTickProvider);
  return ref.watch(servicesProvider).alerts.activeCount();
});

final vehicleDetailProvider =
    FutureProvider.family<VehicleDetail?, String>((ref, vehicleId) async {
  ref.watch(refreshTickProvider);
  return ref.watch(servicesProvider).vehicles.detail(vehicleId);
});

final socHistoryProvider =
    FutureProvider.family<List<HistoryPoint>, String>((ref, vehicleId) async {
  ref.watch(refreshTickProvider);
  return ref.watch(servicesProvider).vehicles.socHistory(vehicleId);
});

final socReadingsProvider =
    FutureProvider.family<List<HistoryPoint>, String>((ref, vehicleId) async {
  ref.watch(refreshTickProvider);
  return ref.watch(servicesProvider).vehicles.recentSocReadings(vehicleId);
});

final vehicleTripsProvider =
    FutureProvider.family<List<Trip>, String>((ref, vehicleId) async {
  ref.watch(refreshTickProvider);
  return ref.watch(servicesProvider).trips.forVehicle(vehicleId);
});

final vehicleAlertsProvider =
    FutureProvider.family<List<FleetAlert>, String>((ref, vehicleId) async {
  ref.watch(refreshTickProvider);
  return ref.watch(servicesProvider).alerts.active(vehicleId: vehicleId);
});

final geofencesProvider = FutureProvider<List<Geofence>>((ref) async {
  ref.watch(refreshTickProvider);
  return ref.watch(servicesProvider).geofences.list();
});
