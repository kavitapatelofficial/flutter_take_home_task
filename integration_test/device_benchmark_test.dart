// The scale exercise, measured on the device rather than on a laptop.
//
// Run:
//   flutter test integration_test/device_benchmark_test.dart -d emulator-5554
//
// This is where the numbers in README.md come from. It runs inside the real
// app process, against the real bundled DuckDB, writing to the real
// application-support directory, so the storage and the CPU being measured are
// the ones the app actually ships on.
//
// Everything is printed rather than asserted, apart from a couple of sanity
// checks: a benchmark that fails the build when a phone is briefly busy is a
// benchmark nobody runs twice.
import 'dart:io';

import 'package:flutter_take_home_task/app/services.dart';
import 'package:flutter_take_home_task/core/clock.dart';
import 'package:flutter_take_home_task/data/db/fleet_db.dart';
import 'package:flutter_take_home_task/data/repo/fleet_repository.dart';
import 'package:flutter_take_home_task/data/sim/backfill.dart';
import 'package:flutter_take_home_task/data/sim/seed.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const clock = SystemClock();
  final out = <String>[];
  void say(String line) {
    out.add(line);
    // ignore: avoid_print
    print('BENCH $line');
  }

  String percentile(List<double> sorted, int pct) =>
      sorted[((pct / 100) * (sorted.length - 1)).round()].toStringAsFixed(1);

  Future<List<double>> time(Future<void> Function() call, {int runs = 50}) async {
    // Unmeasured warm-up passes. The first execution of a query pays for
    // planning, and quoting that as the steady-state figure would be wrong in
    // the flattering direction.
    for (var i = 0; i < 5; i++) {
      await call();
    }
    final samples = <double>[];
    for (var i = 0; i < runs; i++) {
      final sw = Stopwatch()..start();
      await call();
      sw.stop();
      samples.add(sw.elapsedMicroseconds / 1000);
    }
    return samples..sort();
  }

  testWidgets('build, then measure', (tester) async {
    await tester.runAsync(() async {
      say('--- device ---');
      say('os: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
      say('cores: ${Platform.numberOfProcessors}');

      final path = await AppServices.defaultDatabasePath();
      for (final suffix in ['', '.wal']) {
        final file = File('$path$suffix');
        if (file.existsSync()) file.deleteSync();
      }
      say('db: $path');

      // ------------------------------------------------------------ build
      //
      // One handle for the whole build phase. DuckDB gives a file to a single
      // writer, and an earlier version of this benchmark opened a second
      // connection to run the derivation: it reported 0 crossings and 0 trips
      // because the counts were read through a handle that never saw the
      // other one's writes.
      final services = await AppServices.boot(overridePath: path);
      await seedGeofences(
        services.geofences,
        validFrom: DateTime.utc(2020),
      );

      final buildStart = DateTime.now();
      final report = await services.backfill.run();
      say('backfill: ${report.signalRows} rows in '
          '${report.elapsed.inMilliseconds} ms');
      expect(report.signalRows, greaterThan(2000000));

      // Derivation is the expensive half: every vehicle's crossings and trips
      // replayed from its full position history.
      final derivationStart = DateTime.now();
      await services.pipeline.recomputeFleet();
      say('derivation (${Backfill.defaultVehicles} vehicles): '
          '${DateTime.now().difference(derivationStart).inMilliseconds} ms');

      final alertStart = DateTime.now();
      await services.pipeline.alerts.evaluate();
      say('alert sweep (whole fleet): '
          '${DateTime.now().difference(alertStart).inMilliseconds} ms');
      say('total build: '
          '${DateTime.now().difference(buildStart).inMilliseconds} ms');

      final crossings = await services.db.selectOne(
        'SELECT count(*) AS n FROM geofence_events',
      );
      final trips = await services.db.selectOne(
        'SELECT count(*) AS n FROM trips',
      );
      final alerts = await services.db.selectOne(
        'SELECT count(*) AS n FROM alerts',
      );
      say('crossings: ${crossings!['n']}, trips: ${trips!['n']}, '
          'alerts: ${alerts!['n']}');
      expect(crossings['n'], greaterThan(0),
          reason: 'the demo data must actually cross the seeded fences');

      await services.dispose();

      final sizeMb = File(path).lengthSync() / (1024 * 1024);
      say('db file: ${sizeMb.toStringAsFixed(1)} MB');

      // ------------------------------------------------------- cold start
      //
      // Not a process restart -- the app is already running -- so this is
      // "open the database and answer the fleet query", which is the part of
      // cold start this project is responsible for. The Flutter engine start
      // ahead of it is measured separately by the Diagnostics screen, which
      // times from main() to a queryable database.
      final rssBefore = ProcessInfo.currentRss / (1024 * 1024);

      final coldStart = DateTime.now();
      final db = await FleetDb.open(path: path);
      final fleet = FleetRepository(db, clock);
      final firstPage = await fleet.list();
      say('cold open + first fleet query: '
          '${DateTime.now().difference(coldStart).inMilliseconds} ms '
          '(${firstPage.length} rows)');
      expect(firstPage, hasLength(Backfill.defaultVehicles));

      // ------------------------------------------------------------- warm
      final list = await time(() => fleet.list());
      say('fleet list  p50 ${percentile(list, 50)} ms  '
          'p95 ${percentile(list, 95)} ms');

      final counts = await time(() => fleet.counts());
      say('chip counts p50 ${percentile(counts, 50)} ms  '
          'p95 ${percentile(counts, 95)} ms');

      final filtered = await time(() => fleet.list(query: 'eTruck'));
      say('filtered    p50 ${percentile(filtered, 50)} ms  '
          'p95 ${percentile(filtered, 95)} ms');

      // ----------------------------------------------------------- memory
      final rssAfter = ProcessInfo.currentRss / (1024 * 1024);
      // Both figures include the Flutter engine and whatever the build phase
      // above left on the heap, so the absolute number flatters nothing and
      // means little on its own; the delta across opening the database and
      // materialising 500 rows is the part worth quoting.
      say('rss with the list open: ${rssAfter.toStringAsFixed(1)} MB '
          '(before opening the db: ${rssBefore.toStringAsFixed(1)} MB, '
          'delta ${(rssAfter - rssBefore).toStringAsFixed(1)} MB)');

      await db.close();
      say('--- end ---');
    });
  }, timeout: const Timeout(Duration(minutes: 20)));
}
