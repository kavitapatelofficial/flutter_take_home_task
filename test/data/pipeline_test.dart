import 'package:flutter_take_home_task/core/clock.dart';
import 'package:flutter_take_home_task/core/geo.dart';
import 'package:flutter_take_home_task/data/db/fleet_db.dart';
import 'package:flutter_take_home_task/data/ingest/packet.dart';
import 'package:flutter_take_home_task/data/pipeline/telemetry_pipeline.dart';
import 'package:flutter_take_home_task/data/repo/alert_repository.dart';
import 'package:flutter_take_home_task/data/repo/geofence_repository.dart';
import 'package:flutter_take_home_task/data/repo/queries.dart';
import 'package:flutter_take_home_task/data/repo/trip_repository.dart';
import 'package:flutter_take_home_task/domain/model/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/db_harness.dart';

const depotLat = 12.9716;
const depotLon = 77.5946;

void main() {
  late FleetDb db;
  late FixedClock clock;
  late TelemetryPipeline pipeline;
  late AlertRepository alertRepo;
  late GeofenceRepository fenceRepo;
  late TripRepository tripRepo;

  final t0 = DateTime.utc(2026, 9, 4, 8, 0);

  setUp(() async {
    db = await openTestDb();
    clock = FixedClock(t0.add(const Duration(hours: 4)));
    pipeline = TelemetryPipeline(db: db, clock: clock);
    alertRepo = AlertRepository(db, clock);
    fenceRepo = GeofenceRepository(db, clock);
    tripRepo = TripRepository(db);
    await db.execute(
      "INSERT INTO vehicles VALUES ('v1', 'KA01AB1234', 'eTruck 400')",
    );
  });
  tearDown(() async {
    await pipeline.dispose();
    await db.close();
  });

  /// Sends a packet as if measured [ago] before the current clock.
  ///
  /// The clock steps forward a minute per call. Two readings sharing an event
  /// time is not a lifecycle case, it is a duplicate, and the ingest layer
  /// resolves it by keeping the first -- see ingestor_test.dart. Giving each
  /// reading its own instant is what makes these tests about alerts rather
  /// than about tie-breaking.
  Future<void> send(Map<String, double> signals, {Duration? ago}) {
    clock.advance(const Duration(minutes: 1));
    return pipeline.ingest([
      TelemetryPacket(
        vehicleId: 'v1',
        eventTime: clock.nowUtc().subtract(ago ?? Duration.zero),
        signals: signals,
      ),
    ]);
  }

  group('alert lifecycle', () {
    test('crossing 20% opens one warning alert', () async {
      await send({'soc': 45});
      expect(await alertRepo.active(), isEmpty);

      await send({'soc': 18});
      final alerts = await alertRepo.active();
      expect(alerts, hasLength(1));
      expect(alerts.single.kind, AlertKind.batterySoc);
      expect(alerts.single.severity, AlertSeverity.warning);
    });

    test('the two SOC thresholds are one escalating alert, not two', () async {
      await send({'soc': 18});
      final warning = (await alertRepo.active()).single;

      await send({'soc': 8});
      final critical = (await alertRepo.active()).single;

      expect(critical.alertId, warning.alertId,
          reason: 'the same instance escalated');
      expect(critical.severity, AlertSeverity.critical);
      expect(await alertRepo.activeCount(), 1);
    });

    test('charging back above the critical line de-escalates in place',
        () async {
      await send({'soc': 8});
      final critical = (await alertRepo.active()).single;

      await send({'soc': 15});
      final warning = (await alertRepo.active()).single;

      expect(warning.alertId, critical.alertId);
      expect(warning.severity, AlertSeverity.warning);
    });

    test('the condition clearing resolves the alert', () async {
      await send({'soc': 8});
      expect(await alertRepo.activeCount(), 1);

      await send({'soc': 55});
      expect(await alertRepo.active(), isEmpty);

      final row = await db.selectOne('SELECT resolved_at FROM alerts');
      expect(row!['resolved_at'], isNotNull);
    });

    test('battery temperature raises its own critical alert', () async {
      await send({'battery_temp': 48});
      final alerts = await alertRepo.active();
      expect(alerts.single.kind, AlertKind.batteryTemp);
      expect(alerts.single.severity, AlertSeverity.critical);
    });

    test('an overheating battery on a low truck is two separate alerts',
        () async {
      await send({'soc': 8, 'battery_temp': 50});
      expect(await alertRepo.activeCount(), 2);
    });
  });

  group('dismissal', () {
    test('dismissing hides the alert without resolving it', () async {
      await send({'soc': 8});
      final alert = (await alertRepo.active()).single;

      await pipeline.alerts.dismiss(alert.alertId, DismissReason.onIt.name);
      expect(await alertRepo.active(), isEmpty);

      final row = await db.selectOne(
        'SELECT resolved_at, dismiss_reason FROM alerts',
      );
      expect(row!['resolved_at'], isNull, reason: 'still an open condition');
      expect(row['dismiss_reason'], 'onIt');
      expect(await alertRepo.dismissedCount(), 1);
    });

    test('undo puts it straight back', () async {
      await send({'soc': 8});
      final alert = (await alertRepo.active()).single;

      await pipeline.alerts.dismiss(alert.alertId, DismissReason.onIt.name);
      await pipeline.alerts.undoDismiss(alert.alertId);

      expect((await alertRepo.active()).single.alertId, alert.alertId);
    });

    test('a dismissed alert stays hidden while the condition persists',
        () async {
      await send({'soc': 8});
      final alert = (await alertRepo.active()).single;
      await pipeline.alerts.dismiss(
        alert.alertId,
        DismissReason.wrongAlert.name,
      );

      // More readings, still bad. The operator said they were on it.
      await send({'soc': 7});
      await send({'soc': 6});
      expect(await alertRepo.active(), isEmpty);
    });

    test('a condition that clears and returns raises a fresh, visible alert',
        () async {
      // This is the one that would bite an operator: dismissing today's low
      // battery must not suppress tomorrow's.
      await send({'soc': 8});
      final first = (await alertRepo.active()).single;
      await pipeline.alerts.dismiss(first.alertId, DismissReason.onIt.name);
      expect(await alertRepo.active(), isEmpty);

      await send({'soc': 90}); // charged overnight: instance closes
      await send({'soc': 9}); // and drains again the next day

      final second = (await alertRepo.active()).single;
      expect(second.alertId, isNot(first.alertId));
      expect(second.severity, AlertSeverity.critical);
    });
  });

  group('staleness', () {
    test('an alert whose signal goes quiet is hidden but not resolved',
        () async {
      await send({'soc': 8});
      final alert = (await alertRepo.active()).single;

      clock.advance(const Duration(minutes: 30));
      await pipeline.refreshDerivedState();

      expect(await alertRepo.active(), isEmpty,
          reason: 'we make no claim about a signal we cannot see');
      final row = await db.selectOne('SELECT resolved_at FROM alerts');
      expect(row!['resolved_at'], isNull);

      // Back on air, still bad: the same instance reappears rather than a
      // duplicate being raised beside it.
      await send({'soc': 7});
      final again = await alertRepo.active();
      expect(again, hasLength(1));
      expect(again.single.alertId, alert.alertId);
    });

    test('a late packet does not raise an alert about a stale value',
        () async {
      await send({'soc': 60});
      // A packet measured an hour ago finally arrives. It never becomes
      // current, so it cannot open an alert about a battery level the truck
      // left behind long ago.
      await send({'soc': 5}, ago: const Duration(hours: 1));
      expect(await alertRepo.active(), isEmpty);
    });
  });

  group('geofences and trips end to end', () {
    Future<void> sendFix(double metresEast, Duration ago, {double? acc}) {
      final point = offsetMetres(depotLat, depotLon, east: metresEast);
      return pipeline.ingest([
        TelemetryPacket(
          vehicleId: 'v1',
          eventTime: clock.nowUtc().subtract(ago),
          signals: {
            'lat': point.lat,
            'lon': point.lon,
            'gps_accuracy_m': ?acc,
          },
        ),
      ]);
    }

    setUp(() async {
      await fenceRepo.create(
        name: 'Depot',
        lat: depotLat,
        lon: depotLon,
        radiusM: 200,
        validFrom: t0.subtract(const Duration(days: 1)),
      );
      await fenceRepo.create(
        name: 'Customer',
        lat: offsetMetres(depotLat, depotLon, east: 5000).lat,
        lon: offsetMetres(depotLat, depotLon, east: 5000).lon,
        radiusM: 200,
        validFrom: t0.subtract(const Duration(days: 1)),
      );
    });

    test('driving from the depot to a customer produces one completed trip',
        () async {
      await sendFix(50, const Duration(minutes: 60));
      await sendFix(60, const Duration(minutes: 55));
      await sendFix(1000, const Duration(minutes: 50));
      await sendFix(2000, const Duration(minutes: 45));
      await sendFix(4950, const Duration(minutes: 20));
      await sendFix(5000, const Duration(minutes: 15));

      final trips = await tripRepo.forVehicle('v1');
      expect(trips, hasLength(1));
      expect(trips.single.originName, 'Depot');
      expect(trips.single.destinationName, 'Customer');
      expect(trips.single.status, TripStatus.completed);
    });

    test('a departure with no arrival yet stays in progress', () async {
      await sendFix(50, const Duration(minutes: 60));
      await sendFix(1000, const Duration(minutes: 50));
      await sendFix(2000, const Duration(minutes: 45));

      final trips = await tripRepo.forVehicle('v1');
      expect(trips.single.status, TripStatus.inProgress);
      expect(trips.single.destinationName, isNull);
      expect(await tripRepo.inProgressCount(), 1);
    });

    test('re-ingesting the whole day changes nothing', () async {
      final fixes = <List<Object>>[
        [50, 60],
        [60, 55],
        [1000, 50],
        [2000, 45],
        [4950, 20],
        [5000, 15],
      ];
      for (final f in fixes) {
        await sendFix(
          (f[0] as int).toDouble(),
          Duration(minutes: f[1] as int),
        );
      }
      final before = await tripRepo.forVehicle('v1');

      for (final f in fixes) {
        await sendFix(
          (f[0] as int).toDouble(),
          Duration(minutes: f[1] as int),
        );
      }
      final after = await tripRepo.forVehicle('v1');

      expect(after.map((t) => t.tripId), before.map((t) => t.tripId));
      expect(after, hasLength(1));
      final crossings = await db.selectOne(
        'SELECT count(*) AS n FROM geofence_events',
      );
      expect(crossings!['n'], 2);
    });

    test('a late arrival packet completes a trip that was in progress',
        () async {
      await sendFix(50, const Duration(minutes: 60));
      await sendFix(1000, const Duration(minutes: 50));
      await sendFix(2000, const Duration(minutes: 45));
      expect(
        (await tripRepo.forVehicle('v1')).single.status,
        TripStatus.inProgress,
      );

      // The arrival fixes were stuck in a tunnel and turn up now.
      await sendFix(4950, const Duration(minutes: 40));
      await sendFix(5000, const Duration(minutes: 35));

      final trips = await tripRepo.forVehicle('v1');
      expect(trips, hasLength(1), reason: 'revised, not duplicated');
      expect(trips.single.status, TripStatus.completed);
      expect(trips.single.destinationName, 'Customer');
    });

    test('the current geofence is the smallest one containing the vehicle',
        () async {
      await fenceRepo.create(
        name: 'Bengaluru',
        lat: depotLat,
        lon: depotLon,
        radiusM: 20000,
        validFrom: t0.subtract(const Duration(days: 1)),
      );
      await sendFix(50, const Duration(minutes: 5));

      final fences = await fenceRepo.list();
      final depot = fences.firstWhere((f) => f.name == 'Depot');
      final city = fences.firstWhere((f) => f.name == 'Bengaluru');
      expect(depot.vehicleCount, 1);
      expect(city.vehicleCount, 1, reason: 'containment counts both');

      final detail = await db.selectOne('''
        SELECT name FROM (${Q.currentGeofence})
        WHERE vehicle_id = 'v1' AND rank = 1
      ''');
      expect(detail!['name'], 'Depot');
    });

    test('deactivating a fence keeps its trips readable', () async {
      await sendFix(50, const Duration(minutes: 60));
      await sendFix(1000, const Duration(minutes: 50));
      await sendFix(2000, const Duration(minutes: 45));
      await sendFix(4950, const Duration(minutes: 20));
      await sendFix(5000, const Duration(minutes: 15));

      final depotId = (await fenceRepo.list())
          .firstWhere((f) => f.name == 'Depot')
          .geofenceId;
      await fenceRepo.setActive(depotId, active: false);

      final trips = await tripRepo.forVehicle('v1');
      expect(trips.single.originName, 'Depot',
          reason: 'a retired depot still names where the trip started');
    });
  });
}
