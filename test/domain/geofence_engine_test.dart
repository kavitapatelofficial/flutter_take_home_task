import 'package:flutter_take_home_task/core/geo.dart';
import 'package:flutter_take_home_task/domain/engine/geofence_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// A depot fence: 200 m radius in central Bengaluru.
const depotLat = 12.9716;
const depotLon = 77.5946;

FenceVersion depot({
  double radius = 200,
  bool active = true,
  int version = 1,
  DateTime? from,
  DateTime? to,
}) =>
    FenceVersion(
      geofenceId: 'depot',
      version: version,
      lat: depotLat,
      lon: depotLon,
      radiusM: radius,
      active: active,
      validFrom: from ?? DateTime.utc(2020),
      validTo: to,
    );

void main() {
  final t0 = DateTime.utc(2026, 9, 4, 8, 0);
  const engine = GeofenceEngine();

  var packetSeq = 0;

  /// A fix [metresFromCentre] due east of the depot centre.
  Fix at(
    Duration offset,
    double metresFromCentre, {
    double? accuracy,
  }) {
    final point = offsetMetres(depotLat, depotLon, east: metresFromCentre);
    final when = t0.add(offset);
    return Fix(
      eventTime: when,
      ingestTime: when,
      packetId: 'p${packetSeq++}',
      lat: point.lat,
      lon: point.lon,
      accuracyM: accuracy,
    );
  }

  List<GeofenceTransition> run(
    List<Fix> fixes, {
    List<FenceVersion>? versions,
    Map<String, FenceState>? seed,
  }) =>
      engine.run(
        fixes: fixes,
        versions: versions ?? [depot()],
        seed: seed ?? {},
      );

  group('baseline', () {
    test('the first trustworthy fix sets a baseline without inventing a '
        'crossing', () {
      final transitions = run([at(Duration.zero, 50)]);
      expect(transitions, isEmpty,
          reason: 'we never observed it cross anything');
    });

    test('a straightforward departure is one exit', () {
      final transitions = run([
        at(const Duration(minutes: 0), 50),
        at(const Duration(minutes: 1), 60),
        at(const Duration(minutes: 2), 400),
        at(const Duration(minutes: 3), 900),
      ]);
      expect(transitions, hasLength(1));
      expect(transitions.single.kind, TransitionKind.exit);
      expect(transitions.single.uncertain, isFalse);
    });

    test('a round trip out and back is exit then entry', () {
      final transitions = run([
        at(const Duration(minutes: 0), 50),
        at(const Duration(minutes: 1), 500),
        at(const Duration(minutes: 2), 900),
        at(const Duration(minutes: 3), 900),
        at(const Duration(minutes: 4), 100),
        at(const Duration(minutes: 5), 40),
      ]);
      expect(
        transitions.map((t) => t.kind),
        [TransitionKind.exit, TransitionKind.entry],
      );
    });
  });

  group('confirmation', () {
    test('a single outlying fix does not move the vehicle', () {
      final transitions = run([
        at(const Duration(minutes: 0), 50),
        at(const Duration(minutes: 1), 50),
        at(const Duration(minutes: 2), 5000), // one wild fix
        at(const Duration(minutes: 3), 50),
        at(const Duration(minutes: 4), 50),
      ]);
      expect(transitions, isEmpty);
    });

    test('the crossing is dated at the first fix on the new side, not the '
        'one that confirmed it', () {
      final transitions = run([
        at(const Duration(minutes: 0), 50),
        at(const Duration(minutes: 5), 900), // first outside
        at(const Duration(minutes: 6), 950), // confirms
      ]);
      expect(transitions.single.eventTime, t0.add(const Duration(minutes: 5)));
      expect(transitions.single.windowStart, t0);
    });

    test('an interrupted candidate restarts the count', () {
      final transitions = run([
        at(const Duration(minutes: 0), 50),
        at(const Duration(minutes: 1), 900), // candidate outside
        at(const Duration(minutes: 2), 50), // back inside, candidate dropped
        at(const Duration(minutes: 3), 900), // candidate again
      ]);
      expect(transitions, isEmpty, reason: 'only one fix on the new side');
    });
  });

  group('jitter', () {
    test('a vehicle parked on the boundary produces no crossings at all', () {
      // Radius 200 m, hysteresis 25 m: fixes wandering between 190 and 210 m
      // sit inside the band and are evidence of nothing.
      final fixes = <Fix>[at(Duration.zero, 50)];
      for (var i = 1; i <= 40; i++) {
        fixes.add(at(Duration(minutes: i), i.isEven ? 190 : 210));
      }
      expect(run(fixes), isEmpty);
    });

    test('clearing the band by more than the margin does cross', () {
      final transitions = run([
        at(const Duration(minutes: 0), 50),
        at(const Duration(minutes: 1), 226),
        at(const Duration(minutes: 2), 230),
      ]);
      expect(transitions.single.kind, TransitionKind.exit);
    });
  });

  group('accuracy', () {
    test('a fix too inaccurate to trust cannot move the vehicle', () {
      final transitions = run([
        at(const Duration(minutes: 0), 50, accuracy: 5),
        at(const Duration(minutes: 1), 5000, accuracy: 400),
        at(const Duration(minutes: 2), 5000, accuracy: 400),
      ]);
      expect(transitions, isEmpty);
    });

    test('a merely mediocre fix widens the band instead of being discarded',
        () {
      // Accuracy 60 m widens the margin to 60 m, so 240 m out is still inside
      // the band even though it clears the nominal 25 m margin.
      final transitions = run([
        at(const Duration(minutes: 0), 50, accuracy: 5),
        at(const Duration(minutes: 1), 240, accuracy: 60),
        at(const Duration(minutes: 2), 240, accuracy: 60),
      ]);
      expect(transitions, isEmpty);

      final cleared = run([
        at(const Duration(minutes: 0), 50, accuracy: 5),
        at(const Duration(minutes: 1), 300, accuracy: 60),
        at(const Duration(minutes: 2), 300, accuracy: 60),
      ]);
      expect(cleared.single.kind, TransitionKind.exit);
    });
  });

  group('gaps', () {
    test('a crossing across a basement gap is recorded but flagged uncertain',
        () {
      final transitions = run([
        at(const Duration(minutes: 0), 50),
        at(const Duration(hours: 3), 9000),
        at(const Duration(hours: 3, minutes: 1), 9500),
      ]);
      expect(transitions.single.uncertain, isTrue);
      expect(transitions.single.windowStart, t0);
      expect(
        transitions.single.eventTime,
        t0.add(const Duration(hours: 3)),
        reason: 'we date it when we found out, not by inventing a time',
      );
    });

    test('a crossing inside the certainty window is not flagged', () {
      final transitions = run([
        at(const Duration(minutes: 0), 50),
        at(const Duration(minutes: 10), 9000),
        at(const Duration(minutes: 11), 9500),
      ]);
      expect(transitions.single.uncertain, isFalse);
    });
  });

  group('determinism under late arrival', () {
    test('a late fix replayed in event order gives the in-order result', () {
      final inOrder = [
        at(const Duration(minutes: 0), 50),
        at(const Duration(minutes: 1), 60),
        at(const Duration(minutes: 2), 900),
        at(const Duration(minutes: 3), 950),
      ];
      final expected = run(inOrder);

      // The same four fixes, but the minute-2 one turned up last and the
      // caller re-sorted by event time before replaying.
      final shuffled = [inOrder[0], inOrder[1], inOrder[3], inOrder[2]]
        ..sort((a, b) => a.eventTime.compareTo(b.eventTime));
      final replayed = run(shuffled);

      expect(replayed.map((t) => t.eventTime), expected.map((t) => t.eventTime));
      expect(replayed.map((t) => t.kind), expected.map((t) => t.kind));
    });

    test('a late fix can change the answer, and should', () {
      // Without the late fix, two outside readings confirm an exit.
      final withoutLate = run([
        at(const Duration(minutes: 0), 50),
        at(const Duration(minutes: 2), 900),
        at(const Duration(minutes: 4), 950),
      ]);
      expect(withoutLate, hasLength(1));

      // A fix from minute 3 shows it was inside all along: the two outside
      // readings are no longer consecutive, so there is no confirmed exit.
      final withLate = run([
        at(const Duration(minutes: 0), 50),
        at(const Duration(minutes: 2), 900),
        at(const Duration(minutes: 3), 50),
        at(const Duration(minutes: 4), 950),
      ]);
      expect(withLate, isEmpty);
    });
  });

  group('geofence versioning', () {
    test('a fix is judged against the fence as it was at that event time', () {
      final widenedAt = t0.add(const Duration(minutes: 5));
      final versions = [
        depot(radius: 200, to: widenedAt),
        depot(radius: 1000, version: 2, from: widenedAt),
      ];

      // 500 m out: outside the old fence, inside the new one. The fixes
      // before the edit must still read as outside.
      final transitions = run(
        [
          at(const Duration(minutes: 0), 50),
          at(const Duration(minutes: 1), 500),
          at(const Duration(minutes: 2), 500),
          at(const Duration(minutes: 6), 500),
          at(const Duration(minutes: 7), 500),
        ],
        versions: versions,
      );

      expect(
        transitions.map((t) => t.kind),
        [TransitionKind.exit, TransitionKind.entry],
        reason: 'widening the fence re-admits the vehicle from the edit '
            'onward, and leaves the earlier exit standing',
      );
      expect(transitions.first.eventTime, t0.add(const Duration(minutes: 1)));
      expect(transitions.last.eventTime, t0.add(const Duration(minutes: 6)));
    });

    test('a deactivated fence stops producing crossings', () {
      final offAt = t0.add(const Duration(minutes: 2));
      final versions = [
        depot(to: offAt),
        depot(version: 2, active: false, from: offAt),
      ];
      final transitions = run(
        [
          at(const Duration(minutes: 0), 50),
          at(const Duration(minutes: 3), 900),
          at(const Duration(minutes: 4), 950),
        ],
        versions: versions,
      );
      expect(transitions, isEmpty);
    });

    test('a fence that did not exist yet judges nothing', () {
      final versions = [depot(from: t0.add(const Duration(hours: 1)))];
      final transitions = run(
        [
          at(const Duration(minutes: 0), 50),
          at(const Duration(minutes: 1), 900),
          at(const Duration(minutes: 2), 950),
        ],
        versions: versions,
      );
      expect(transitions, isEmpty);
    });
  });

  test('overlapping fences are folded independently', () {
    final city = FenceVersion(
      geofenceId: 'city',
      version: 1,
      lat: depotLat,
      lon: depotLon,
      radiusM: 2000,
      active: true,
      validFrom: DateTime.utc(2020),
    );

    final transitions = run(
      [
        at(const Duration(minutes: 0), 50),
        at(const Duration(minutes: 1), 900), // out of depot, still in city
        at(const Duration(minutes: 2), 950),
        at(const Duration(minutes: 3), 5000), // out of city too
        at(const Duration(minutes: 4), 5500),
      ],
      versions: [depot(), city],
    );

    expect(transitions, hasLength(2));
    expect(transitions.first.geofenceId, 'depot');
    expect(transitions.last.geofenceId, 'city');
    expect(transitions.every((t) => t.kind == TransitionKind.exit), isTrue);
  });

  test('state carried across runs continues where the last one stopped', () {
    final seed = <String, FenceState>{};
    final first = run([at(const Duration(minutes: 0), 50)], seed: seed);
    expect(first, isEmpty);

    // A later batch, same seed: the baseline from the first run still counts.
    final second = run(
      [
        at(const Duration(minutes: 1), 900),
        at(const Duration(minutes: 2), 950),
      ],
      seed: seed,
    );
    expect(second.single.kind, TransitionKind.exit);
    expect(second.single.windowStart, t0);
  });
}
