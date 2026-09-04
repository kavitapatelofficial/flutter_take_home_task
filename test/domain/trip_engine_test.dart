import 'package:flutter_take_home_task/domain/engine/geofence_engine.dart';
import 'package:flutter_take_home_task/domain/engine/trip_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 4, 8, 0);
  const engine = TripEngine();

  GeofenceTransition exit(String fence, int minute, {bool uncertain = false}) =>
      GeofenceTransition(
        geofenceId: fence,
        kind: TransitionKind.exit,
        eventTime: t0.add(Duration(minutes: minute)),
        windowStart: t0,
        uncertain: uncertain,
      );

  GeofenceTransition entry(String fence, int minute, {bool uncertain = false}) =>
      GeofenceTransition(
        geofenceId: fence,
        kind: TransitionKind.entry,
        eventTime: t0.add(Duration(minutes: minute)),
        windowStart: t0,
        uncertain: uncertain,
      );

  List<DerivedTrip> run(List<GeofenceTransition> transitions) =>
      engine.run(vehicleId: 'v1', transitions: transitions);

  test('an exit starts a trip and the next entry completes it', () {
    final trips = run([exit('depot', 0), entry('customer', 45)]);
    expect(trips, hasLength(1));
    expect(trips.single.originGeofenceId, 'depot');
    expect(trips.single.destinationGeofenceId, 'customer');
    expect(trips.single.startedAt, t0);
    expect(trips.single.endedAt, t0.add(const Duration(minutes: 45)));
    expect(trips.single.inProgress, isFalse);
  });

  test('an exit with no entry yet stays in progress', () {
    final trips = run([exit('depot', 0)]);
    expect(trips.single.inProgress, isTrue);
    expect(trips.single.destinationGeofenceId, isNull);
  });

  test('returning to the origin is a valid trip', () {
    final trips = run([exit('depot', 0), entry('depot', 90)]);
    expect(trips.single.originGeofenceId, 'depot');
    expect(trips.single.destinationGeofenceId, 'depot');
  });

  test('a day of hops produces one trip per leg', () {
    final trips = run([
      exit('depot', 0),
      entry('customer_a', 40),
      exit('customer_a', 60),
      entry('customer_b', 95),
      exit('customer_b', 120),
      entry('depot', 180),
    ]);
    expect(trips, hasLength(3));
    expect(
      trips.map((t) => '${t.originGeofenceId}>${t.destinationGeofenceId}'),
      ['depot>customer_a', 'customer_a>customer_b', 'customer_b>depot'],
    );
    expect(trips.every((t) => !t.inProgress), isTrue);
  });

  test('only the last trip of a day can be in progress', () {
    final trips = run([
      exit('depot', 0),
      entry('customer_a', 40),
      exit('customer_a', 60),
    ]);
    expect(trips.where((t) => t.inProgress), hasLength(1));
    expect(trips.last.inProgress, isTrue);
  });

  group('overlapping fences', () {
    test('leaving an inner fence while still inside an outer one is not a trip',
        () {
      // The truck is in the depot, which sits inside a city fence. Rolling out
      // of the depot gate has not started a journey; leaving the city has.
      final overlapped = run([
        exit('depot', 0),
        exit('city', 5),
        entry('city', 100),
        entry('depot', 105),
      ]);
      expect(overlapped, hasLength(1));
      expect(
        overlapped.single.startedAt,
        t0.add(const Duration(minutes: 5)),
        reason: 'the trip starts when it left the outermost fence, not the '
            'depot gate',
      );
      expect(overlapped.single.originGeofenceId, 'city');
      expect(
        overlapped.single.endedAt,
        t0.add(const Duration(minutes: 100)),
        reason: 'and ends on the first fence it re-entered',
      );
    });

    test('moving between two overlapping fences never opens a second trip', () {
      final trips = run([
        exit('depot', 0),
        exit('city', 5),
        entry('city', 60),
        exit('city', 70),
        entry('depot', 120),
      ]);
      expect(trips, hasLength(2));
      expect(trips.every((t) => t.originGeofenceId == 'city'), isTrue);
    });
  });

  group('idempotency and revision', () {
    test('re-deriving the same crossings produces identical trips', () {
      final input = [
        exit('depot', 0),
        entry('customer', 45),
        exit('customer', 60),
      ];
      final first = run(input);
      final second = run([...input.reversed]);

      expect(
        second.map((t) => t.tripId),
        first.map((t) => t.tripId),
        reason: 'trip identity is a pure function of origin and start time',
      );
    });

    test('a late packet that revises a boundary revises the trip in place', () {
      final before = run([exit('depot', 0)]);
      // A late fix moved the confirmed exit earlier and supplied a
      // destination. The completed trip must not sit beside the old one.
      final after = run([exit('depot', 0), entry('customer', 45)]);

      expect(after, hasLength(1));
      expect(after.single.tripId, before.single.tripId,
          reason: 'same origin and start, so the same row is updated');
      expect(after.single.destinationGeofenceId, 'customer');
    });

    test('a revised start time yields a different trip identity', () {
      final a = run([exit('depot', 0), entry('customer', 45)]);
      final b = run([exit('depot', 3), entry('customer', 45)]);
      expect(b.single.tripId, isNot(a.single.tripId));
      expect(b, hasLength(1),
          reason: 'the caller replaces the vehicle window wholesale, so a '
              'revised start does not leave the old row behind');
    });
  });

  test('uncertainty on a crossing carries into the trip boundary', () {
    final trips = run([
      exit('depot', 0, uncertain: true),
      entry('customer', 45),
    ]);
    expect(trips.single.startUncertain, isTrue);
    expect(trips.single.endUncertain, isFalse);
  });

  test('an entry with no open trip does not fabricate one', () {
    final trips = run([entry('depot', 10)]);
    expect(trips, isEmpty);
  });

  test('simultaneous exit and entry is a handover, not a trip', () {
    // Two adjacent sites sharing a boundary, crossed in the same instant.
    final trips = run([exit('site_a', 30), entry('site_b', 30)]);
    expect(trips, isEmpty,
        reason: 'processing the exit first keeps occupancy from emptying');
  });
}
