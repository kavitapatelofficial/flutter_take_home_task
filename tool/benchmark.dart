// Scale exercise harness.
//
// Builds a 500-vehicle database with more than two million signal rows, then
// measures the three numbers the brief asks for:
//
//   1. cold start to a painted fleet list -- database open, schema check, and
//      the fleet query, from a process that has never touched the file
//   2. the fleet query warm, p50 and p95
//   3. memory at rest with the list loaded
//
// Run:  dart run tool/benchmark.dart [--vehicles 500] [--samples 700]
//
// This measures the data layer on the host. The device numbers in README.md
// come from the same queries run inside the app on a Pixel 7 emulator, via the
// Diagnostics screen, because a host-side number would flatter the storage and
// the CPU and would not be the thing anyone cares about.
import 'dart:io';

import 'package:flutter_take_home_task/core/clock.dart';
import 'package:flutter_take_home_task/data/db/fleet_db.dart';
import 'package:flutter_take_home_task/data/pipeline/derivation_processor.dart';
import 'package:flutter_take_home_task/data/repo/fleet_repository.dart';
import 'package:flutter_take_home_task/data/repo/geofence_repository.dart';
import 'package:flutter_take_home_task/data/sim/backfill.dart';
import 'package:flutter_take_home_task/data/sim/seed.dart';

Future<void> main(List<String> args) async {
  final vehicles = _intArg(args, '--vehicles') ?? Backfill.defaultVehicles;
  final samples =
      _intArg(args, '--samples') ?? Backfill.defaultSamplesPerVehicle;

  // Building 2.6M rows leaves the process holding the memory it took to build
  // them, which is not what "memory at rest with the list open" means. So the
  // build and the measurement are two runs: --build writes the file and exits,
  // --measure opens it in a process that has done nothing else.
  final buildOnly = args.contains('--build');
  final measureOnly = args.contains('--measure');

  final root = Directory.current.path;
  final lib = [
    '$root/.native/libduckdb.dylib',
    '$root/.native/libduckdb.so',
  ].firstWhere((p) => File(p).existsSync(), orElse: () => '');
  if (lib.isEmpty) {
    stderr.writeln('Run tool/fetch_duckdb_native.sh first.');
    exit(1);
  }
  FleetDb.useNativeLibrary(lib);

  final dir = Directory('$root/bench_out')..createSync(recursive: true);
  final path = '${dir.path}/fleet.duckdb';

  const clock = SystemClock();

  if (measureOnly) {
    await _measure(path, clock);
    return;
  }

  if (File(path).existsSync()) File(path).deleteSync();

  // ---------------------------------------------------------------- build
  stdout.writeln('Building $vehicles vehicles x $samples samples...');
  var db = await FleetDb.open(path: path);
  await seedGeofences(
    GeofenceRepository(db, clock),
    validFrom: DateTime.utc(2020),
  );

  final report = await Backfill(db, clock).run(
    vehicles: vehicles,
    samplesPerVehicle: samples,
    onStage: (stage) => stdout.write('  $stage...'),
  );
  stdout.writeln('\n  $report');

  final derivationStart = DateTime.now();
  await DerivationProcessor(db).recomputeAll([
    for (var i = 0; i < vehicles; i++) 'v$i',
  ]);
  final derivationMs = DateTime.now().difference(derivationStart).inMilliseconds;
  stdout.writeln('  derivation (crossings + trips, whole fleet): $derivationMs ms');

  final crossings = await db.selectOne('SELECT count(*) AS n FROM geofence_events');
  final trips = await db.selectOne('SELECT count(*) AS n FROM trips');
  stdout.writeln('  ${crossings!['n']} crossings, ${trips!['n']} trips');

  await db.close();

  final sizeMb = File(path).lengthSync() / (1024 * 1024);
  stdout.writeln('  database file: ${sizeMb.toStringAsFixed(1)} MB');

  if (buildOnly) {
    stdout.writeln('\nBuilt. Now run:  dart run tool/benchmark.dart --measure');
    return;
  }
  stdout.writeln('\n(Same-process figures below; --build then --measure for '
      'honest cold-start and memory numbers.)');
  await _measure(path, clock);
}

/// Opens an existing database and measures it. Kept as its own entry point so
/// it can run in a process that has not just allocated its way through a
/// backfill.
Future<void> _measure(String path, Clock clock) async {
  if (!File(path).existsSync()) {
    stderr.writeln('No database at $path. Run with --build first.');
    exit(1);
  }
  final baselineRss = ProcessInfo.currentRss / (1024 * 1024);
  FleetDb db;

  // ----------------------------------------------------------- cold start
  //
  // The OS page cache is still warm from whoever wrote the file, so this is an
  // optimistic figure and the README labels it as one. It is the cost of
  // opening the database and running the fleet query, not of launching Flutter.
  final coldStart = DateTime.now();
  db = await FleetDb.open(path: path);
  final fleet = FleetRepository(db, clock);
  final firstPage = await fleet.list();
  final coldMs = DateTime.now().difference(coldStart).inMilliseconds;
  stdout.writeln('\nCold open + first fleet query: $coldMs ms '
      '(${firstPage.length} rows)');

  // ------------------------------------------------------------ warm p50/p95
  final samplesMs = <double>[];
  for (var i = 0; i < 60; i++) {
    final sw = Stopwatch()..start();
    await fleet.list();
    sw.stop();
    samplesMs.add(sw.elapsedMicroseconds / 1000);
  }
  samplesMs.sort();

  final countsMs = <double>[];
  for (var i = 0; i < 60; i++) {
    final sw = Stopwatch()..start();
    await fleet.counts();
    sw.stop();
    countsMs.add(sw.elapsedMicroseconds / 1000);
  }
  countsMs.sort();

  stdout.writeln('Fleet list (warm)   p50 ${_p(samplesMs, 50)} ms  '
      'p95 ${_p(samplesMs, 95)} ms');
  stdout.writeln('Filter counts       p50 ${_p(countsMs, 50)} ms  '
      'p95 ${_p(countsMs, 95)} ms');

  // ---------------------------------------------------------------- memory
  final rssMb = ProcessInfo.currentRss / (1024 * 1024);
  stdout.writeln('Process RSS at rest with the list loaded: '
      '${rssMb.toStringAsFixed(1)} MB '
      '(baseline before opening the database: '
      '${baselineRss.toStringAsFixed(1)} MB)');

  await db.close();
}

String _p(List<double> sorted, int percentile) {
  final index = ((percentile / 100) * (sorted.length - 1)).round();
  return sorted[index].toStringAsFixed(1);
}

int? _intArg(List<String> args, String name) {
  final i = args.indexOf(name);
  return i == -1 || i + 1 >= args.length ? null : int.tryParse(args[i + 1]);
}
