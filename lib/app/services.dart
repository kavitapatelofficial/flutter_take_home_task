import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/clock.dart';
import '../data/db/fleet_db.dart';
import '../data/pipeline/telemetry_pipeline.dart';
import '../data/repo/alert_repository.dart';
import '../data/repo/fleet_repository.dart';
import '../data/repo/geofence_repository.dart';
import '../data/repo/trip_repository.dart';
import '../data/repo/vehicle_repository.dart';
import '../data/sim/backfill.dart';
import '../data/sim/live_simulator.dart';
import '../data/sim/seed.dart';

/// Everything the UI is allowed to talk to.
///
/// Assembled once at startup and handed to the widget tree, so no screen ever
/// constructs a repository or reaches for a database handle of its own.
class AppServices {
  AppServices._({
    required this.db,
    required this.clock,
    required this.pipeline,
    required this.fleet,
    required this.vehicles,
    required this.alerts,
    required this.geofences,
    required this.trips,
    required this.backfill,
    required this.retention,
    required this.simulator,
    required this.startupMillis,
  });

  final FleetDb db;
  final Clock clock;
  final TelemetryPipeline pipeline;
  final FleetRepository fleet;
  final VehicleRepository vehicles;
  final AlertRepository alerts;
  final GeofenceRepository geofences;
  final TripRepository trips;
  final Backfill backfill;
  final Retention retention;
  final LiveSimulator simulator;

  /// How long it took to get from process start to a database that could
  /// answer the fleet query. Reported on the Diagnostics screen; it is the
  /// cold-start number the brief asks for, measured on the device rather than
  /// guessed at.
  final int startupMillis;

  static Future<AppServices> boot({
    Clock clock = const SystemClock(),
    String? overridePath,
    Stopwatch? since,
  }) async {
    final watch = since ?? (Stopwatch()..start());

    final path = overridePath ?? await defaultDatabasePath();
    final db = await FleetDb.open(path: path);

    final pipeline = TelemetryPipeline(db: db, clock: clock);
    final geofences = GeofenceRepository(db, clock);

    // The fences exist from long ago so that backfilled history is judged
    // against them rather than falling outside their validity window.
    await seedGeofences(geofences, validFrom: DateTime.utc(2020));

    final services = AppServices._(
      db: db,
      clock: clock,
      pipeline: pipeline,
      fleet: FleetRepository(db, clock),
      vehicles: VehicleRepository(db, clock),
      alerts: AlertRepository(db, clock),
      geofences: geofences,
      trips: TripRepository(db),
      backfill: Backfill(db, clock),
      retention: Retention(db, clock),
      simulator: LiveSimulator(pipeline: pipeline, clock: clock),
      startupMillis: watch.elapsedMilliseconds,
    );

    return services;
  }

  /// Where the database lives on device.
  ///
  /// Application support, not a cache or temp directory: this is the app's
  /// state, and the whole point of local-first is that it survives a restart
  /// and is not something the OS may reclaim.
  static Future<String> defaultDatabasePath() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return p.join(dir.path, 'fleet.duckdb');
  }

  /// Deletes the database file. Used by the Diagnostics reset action.
  static Future<void> deleteDatabaseFile() async {
    final path = await defaultDatabasePath();
    for (final suffix in ['', '.wal']) {
      final file = File('$path$suffix');
      if (file.existsSync()) file.deleteSync();
    }
  }

  Future<void> dispose() async {
    simulator.stop();
    await pipeline.dispose();
    await db.close();
  }
}
