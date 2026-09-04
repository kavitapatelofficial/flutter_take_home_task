import 'package:flutter_take_home_task/core/clock.dart';
import 'package:flutter_take_home_task/data/db/fleet_db.dart';
import 'package:flutter_take_home_task/data/repo/fleet_repository.dart';
import 'package:flutter_take_home_task/data/repo/geofence_repository.dart';
import 'package:flutter_take_home_task/data/repo/vehicle_repository.dart';
import 'package:flutter_take_home_task/data/sim/backfill.dart';
import 'package:flutter_take_home_task/data/sim/seed.dart';
import 'package:flutter_take_home_task/domain/model/vehicle_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/db_harness.dart';

void main() {
  late FleetDb db;
  late FixedClock clock;

  final now = DateTime.utc(2026, 9, 4, 12);

  setUp(() async {
    db = await openTestDb();
    clock = FixedClock(now);
    await seedGeofences(
      GeofenceRepository(db, clock),
      validFrom: DateTime.utc(2020),
    );
  });
  tearDown(() async => db.close());

  test('backfill produces a fleet with a spread of statuses and alerts',
      () async {
    // A tenth of the real thing: same generator, same shape, fast enough for
    // a test suite.
    final report = await Backfill(db, clock).run(
      vehicles: 50,
      samplesPerVehicle: 200,
    );
    expect(report.vehicles, 50);
    expect(report.signalRows, 50 * (200 * 6 + 100 * 3));

    final counts = await FleetRepository(db, clock).counts();
    expect(counts.total, 50);
    // Every bucket wants to be reachable, otherwise the demo data is not
    // exercising the screen it is there to fill.
    for (final status in VehicleStatus.values) {
      expect(counts[status], greaterThan(0), reason: 'no ${status.label}');
    }
  });

  test('the seeded fences overlap, so a vehicle sits inside more than one',
      () async {
    await Backfill(db, clock).run(vehicles: 10, samplesPerVehicle: 20);
    final fences = await GeofenceRepository(db, clock).list();
    expect(fences, hasLength(4));
    expect(
      fences.where((f) => f.vehicleCount > 0).length,
      greaterThanOrEqualTo(2),
      reason: 'the ORR fence should contain vehicles that are also in a depot',
    );
  });

  group('retention', () {
    test('compaction rolls old readings up and drops the raw rows', () async {
      await Backfill(db, clock).run(vehicles: 5, samplesPerVehicle: 60);

      final rawBefore = (await db.selectOne(
        'SELECT count(*) AS n FROM signal_readings',
      ))!['n'] as int;

      // Jump far enough forward that everything falls outside the raw window.
      clock.advance(const Duration(days: 30));
      final report = await Retention(db, clock).compact();

      expect(report.rowsDropped, rawBefore);
      expect(report.rollupRows, greaterThan(0));

      final rawAfter = (await db.selectOne(
        'SELECT count(*) AS n FROM signal_readings',
      ))!['n'] as int;
      expect(rawAfter, 0);
    });

    test('positions are dropped rather than rolled up', () async {
      await Backfill(db, clock).run(vehicles: 5, samplesPerVehicle: 60);
      clock.advance(const Duration(days: 30));
      await Retention(db, clock).compact();

      final positionRollups = await db.selectOne(
        "SELECT count(*) AS n FROM signal_rollups "
        "WHERE signal IN ('lat', 'lon', 'gps_accuracy_m')",
      );
      expect(positionRollups!['n'], 0,
          reason: 'an averaged latitude is worse than no latitude');
    });

    test('the SOC chart still has points after compaction', () async {
      await Backfill(db, clock).run(vehicles: 5, samplesPerVehicle: 60);
      clock.advance(const Duration(days: 30));
      await Retention(db, clock).compact();

      // Look back far enough to cover the rolled-up window.
      final history = await VehicleRepository(db, clock).socHistory(
        'v0',
        window: const Duration(days: 40),
      );
      expect(history, isNotEmpty,
          reason: 'history survives the retention boundary as buckets');
    });

    test('an alert still open is never compacted away', () async {
      await db.execute(
        "INSERT INTO alerts VALUES ('a1', 'v0', 'battery_soc', 'critical', "
        '5.0, ?, ?, NULL, NULL, NULL)',
        [now.subtract(const Duration(days: 300)), now],
      );
      clock.advance(const Duration(days: 400));
      await Retention(db, clock).compact();

      final row = await db.selectOne('SELECT count(*) AS n FROM alerts');
      expect(row!['n'], 1);
    });
  });
}
