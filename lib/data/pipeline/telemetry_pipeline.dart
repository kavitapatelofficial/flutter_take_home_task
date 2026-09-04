import 'dart:async';

import '../../core/clock.dart';
import '../db/fleet_db.dart';
import '../ingest/ingestor.dart';
import '../ingest/packet.dart';
import 'alert_processor.dart';
import 'derivation_processor.dart';

/// The write path, end to end.
///
/// Everything that changes state goes through here in a fixed order: the log
/// first, then current state, then alerts, then the derived geofence and trip
/// layers. Order matters -- alerts read current state, and derivation reads
/// the log -- and having exactly one place that knows the order means the UI
/// never has to.
class TelemetryPipeline {
  TelemetryPipeline({
    required FleetDb db,
    required Clock clock,
    Ingestor? ingestor,
    AlertProcessor? alerts,
    DerivationProcessor? derivation,
  })  : _db = db,
        _ingestor = ingestor ?? Ingestor(db, clock),
        alerts = alerts ?? AlertProcessor(db, clock),
        _derivation = derivation ?? DerivationProcessor(db);

  final FleetDb _db;
  final Ingestor _ingestor;
  final AlertProcessor alerts;
  final DerivationProcessor _derivation;

  final _changes = StreamController<void>.broadcast();

  /// Ticks after anything that could change what a screen is showing.
  ///
  /// Deliberately carries no payload. Screens re-query rather than trying to
  /// patch themselves from a delta, because the database is the source of
  /// truth and a widget holding a divergent copy of it is the bug this whole
  /// architecture is meant to rule out.
  Stream<void> get changes => _changes.stream;

  Future<IngestResult> ingest(List<TelemetryPacket> packets) async {
    final result = await _ingestor.ingest(packets);
    if (result.touched.isNotEmpty) {
      await alerts.evaluate(vehicleIds: result.touched.keys);
      await _derivation.recomputeAll(result.touched.keys);
    }
    notifyChanged();
    return result;
  }

  /// Re-evaluates conditions across the fleet without new data arriving.
  ///
  /// Needed because staleness is a function of wall clock: a vehicle goes
  /// OFFLINE, and an alert goes quiet, purely by the passage of time.
  Future<void> refreshDerivedState() async {
    await alerts.evaluate();
    notifyChanged();
  }

  /// Recomputes crossings and trips for the whole fleet.
  ///
  /// Editing a fence changes what its geometry means from the edit forward, so
  /// every vehicle has to be re-judged against it.
  Future<void> recomputeFleet() async {
    final rows = await _db.select('SELECT vehicle_id FROM vehicles');
    await _derivation.recomputeAll(
      rows.map((r) => r['vehicle_id'] as String),
    );
    notifyChanged();
  }

  void notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() => _changes.close();
}
