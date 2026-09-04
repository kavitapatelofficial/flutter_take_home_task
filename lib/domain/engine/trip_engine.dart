import '../../core/ids.dart';
import 'geofence_engine.dart';

class DerivedTrip {
  const DerivedTrip({
    required this.tripId,
    required this.vehicleId,
    required this.originGeofenceId,
    required this.startedAt,
    required this.startUncertain,
    this.destinationGeofenceId,
    this.endedAt,
    this.endUncertain = false,
  });

  final String tripId;
  final String vehicleId;
  final String? originGeofenceId;
  final DateTime startedAt;
  final bool startUncertain;
  final String? destinationGeofenceId;
  final DateTime? endedAt;
  final bool endUncertain;

  bool get inProgress => endedAt == null;
}

/// Builds trips from confirmed geofence crossings.
///
/// The rule the spec gives is a two-state machine: a confirmed exit starts a
/// trip, the next confirmed entry completes it, and with no entry the trip
/// stays in progress. What the spec leaves open is what "exit" means when
/// fences overlap, and the answer here is that a trip is about being *away*,
/// not about being outside one particular circle.
///
/// So we fold the crossings into a set of currently-occupied fences. A trip
/// starts on the exit that empties that set, and completes on the entry that
/// refills it. A vehicle moving between two overlapping fences without ever
/// being outside both has not taken a trip -- it never left. A vehicle that
/// leaves the depot and comes back to the same depot has, which is why the
/// origin and destination are allowed to be equal.
///
/// The one-active-trip invariant falls out of the machine rather than being
/// enforced on top of it: a trip can only start from a non-empty occupancy
/// set, and starting one empties it, so a second exit cannot open a second
/// trip.
///
/// Idempotency comes from this being a total function of the crossing list.
/// The caller re-derives a vehicle's trips from all of its crossings and
/// replaces them wholesale, so processing the same packets twice produces the
/// same rows, and a late packet that revises a crossing revises the trip that
/// crossing produced instead of adding a second one beside it.
class TripEngine {
  const TripEngine();

  List<DerivedTrip> run({
    required String vehicleId,
    required List<GeofenceTransition> transitions,
    Set<String> initiallyInside = const {},
  }) {
    final ordered = _ordered(transitions);
    final occupied = <String>{...initiallyInside, ..._inferInitial(ordered)};
    final trips = <DerivedTrip>[];

    String? openOrigin;
    DateTime? openStart;
    var openUncertain = false;

    for (final transition in ordered) {
      switch (transition.kind) {
        case TransitionKind.exit:
          final wasInside = occupied.remove(transition.geofenceId);
          if (wasInside && occupied.isEmpty && openStart == null) {
            // Left everywhere we know about: the trip begins. The origin is
            // the fence whose exit emptied the set -- with overlapping
            // fences that is the outermost one the vehicle was still in, and
            // it is the last place we can honestly say it was.
            openOrigin = transition.geofenceId;
            openStart = transition.eventTime;
            openUncertain = transition.uncertain;
          }

        case TransitionKind.entry:
          final wasAway = occupied.isEmpty;
          occupied.add(transition.geofenceId);
          if (wasAway && openStart != null) {
            trips.add(
              DerivedTrip(
                tripId: _idFor(vehicleId, openOrigin, openStart),
                vehicleId: vehicleId,
                originGeofenceId: openOrigin,
                startedAt: openStart,
                startUncertain: openUncertain,
                destinationGeofenceId: transition.geofenceId,
                endedAt: transition.eventTime,
                endUncertain: transition.uncertain,
              ),
            );
            openOrigin = null;
            openStart = null;
            openUncertain = false;
          }
      }
    }

    if (openStart != null) {
      trips.add(
        DerivedTrip(
          tripId: _idFor(vehicleId, openOrigin, openStart),
          vehicleId: vehicleId,
          originGeofenceId: openOrigin,
          startedAt: openStart,
          startUncertain: openUncertain,
        ),
      );
    }

    return trips;
  }

  /// Which fences the vehicle must already have been sitting in when the
  /// crossing list opens.
  ///
  /// A vehicle does not exit somewhere it was never inside, so a fence whose
  /// first crossing in the list is an exit tells us it was occupied at the
  /// start. Without this the fold gets overlapping fences wrong: a truck
  /// inside both the depot and the wider city fence, exiting the depot first,
  /// would look like it had left everywhere and would open a trip while it
  /// was demonstrably still in the city fence.
  Set<String> _inferInitial(List<GeofenceTransition> ordered) {
    final seen = <String>{};
    final inside = <String>{};
    for (final transition in ordered) {
      if (!seen.add(transition.geofenceId)) continue;
      if (transition.kind == TransitionKind.exit) {
        inside.add(transition.geofenceId);
      }
    }
    return inside;
  }

  /// Ordering is part of the contract, not an implementation detail: two
  /// crossings at the same instant on different fences must fold the same way
  /// on every replay or the trip list would flicker between runs.
  ///
  /// Entries sort before exits at equal timestamps. Two adjacent sites
  /// sharing a boundary produce an exit from one and an entry to the other on
  /// the same fix; applying what the vehicle *is* inside before removing what
  /// it left keeps the occupancy set from momentarily emptying and inventing a
  /// zero-length trip between neighbours.
  List<GeofenceTransition> _ordered(List<GeofenceTransition> transitions) {
    final sorted = [...transitions];
    sorted.sort((a, b) {
      final byTime = a.eventTime.compareTo(b.eventTime);
      if (byTime != 0) return byTime;
      if (a.kind != b.kind) {
        return a.kind == TransitionKind.entry ? -1 : 1;
      }
      return a.geofenceId.compareTo(b.geofenceId);
    });
    return sorted;
  }

  /// Trip identity is a pure function of where and when it started, so a
  /// re-derivation lands on the same primary key.
  String _idFor(String vehicleId, String? origin, DateTime startedAt) =>
      stableId([
        'trip',
        vehicleId,
        origin ?? '-',
        startedAt.microsecondsSinceEpoch,
      ]);
}
