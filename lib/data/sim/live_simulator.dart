import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/clock.dart';
import '../../core/geo.dart';
import '../ingest/packet.dart';
import '../pipeline/telemetry_pipeline.dart';
import 'backfill.dart';

/// Keeps the demo fleet moving.
///
/// This is not a toy: it is the only way to see the parts of the app that are
/// about time passing. Vehicles go stale and drop offline, batteries drain
/// through the alert thresholds, trucks cross fences and open trips.
///
/// It also deliberately misbehaves, because the interesting behaviour is in
/// the misbehaviour. On each tick a slice of packets are duplicated, a slice
/// are held back and delivered several minutes late, and one vehicle in
/// twenty stops reporting for a while and then dumps its backlog. If the
/// dedupe, the late-packet rule and the replay are wrong, this is what shows
/// it -- trips flickering, alerts doubling, counts drifting.
class LiveSimulator {
  LiveSimulator({
    required TelemetryPipeline pipeline,
    required Clock clock,
    this.vehicleCount = 40,
    this.interval = const Duration(seconds: 3),
    int seed = 7,
  })  : _pipeline = pipeline,
        _clock = clock,
        _random = Random(seed);

  final TelemetryPipeline _pipeline;
  final Clock _clock;
  final Random _random;

  /// How many vehicles are live. A slice of the fleet, not all of it, so the
  /// OFFLINE bucket stays populated.
  final int vehicleCount;
  final Duration interval;

  Timer? _timer;

  /// Packets held back to arrive late, with the tick they are due on.
  final _delayed = <(int, TelemetryPacket)>[];
  final _soc = <int, double>{};
  final _phase = <int, double>{};
  var _tick = 0;

  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => _emit());
    _emit();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _emit() async {
    _tick++;
    final now = _clock.nowUtc();
    final packets = <TelemetryPacket>[];

    // Anything whose delivery was deferred and is now due.
    _delayed.removeWhere((entry) {
      if (entry.$1 > _tick) return false;
      packets.add(entry.$2);
      return true;
    });

    for (var i = 0; i < vehicleCount; i++) {
      // One vehicle in twenty is in a basement this tick: nothing goes out
      // now, and it all arrives together a few ticks later.
      final silent = (i + _tick) % 20 == 0;

      final soc = _soc.update(
        i,
        (v) => v <= 4 ? 100 : v - (0.4 + _random.nextDouble() * 0.5),
        ifAbsent: () => 30 + _random.nextDouble() * 65,
      );
      final phase = _phase.update(
        i,
        (v) => v + 0.06,
        ifAbsent: () => _random.nextDouble() * pi * 2,
      );

      final frac = (sin(phase) + 1) / 2;
      final lat = Backfill.seedDepotLat +
          frac * (Backfill.seedCustomerLat - Backfill.seedDepotLat);
      final lon = Backfill.seedDepotLon +
          frac * (Backfill.seedCustomerLon - Backfill.seedDepotLon);
      // A few metres of noise: realistic, and well inside the hysteresis band.
      final jitter = offsetMetres(
        lat,
        lon,
        north: (_random.nextDouble() - 0.5) * 14,
        east: (_random.nextDouble() - 0.5) * 14,
      );

      final moving = frac > 0.08 && frac < 0.92;
      final packet = TelemetryPacket(
        vehicleId: 'v$i',
        eventTime: now,
        signals: {
          'soc': double.parse(soc.toStringAsFixed(1)),
          'range_km': double.parse((soc * 4.2).toStringAsFixed(1)),
          'speed': moving ? 20 + _random.nextDouble() * 45 : 0,
          'ignition': moving || i % 4 == 0 ? 1 : 0,
          'battery_temp': 26 +
              (moving ? 14 : 0) +
              _random.nextDouble() * (i % 9 == 0 ? 12 : 5),
          'odometer': 120000 + i * 137 + _tick * 0.4,
          'lat': jitter.lat,
          'lon': jitter.lon,
          'gps_accuracy_m': i % 17 == 0
              ? 120 + _random.nextDouble() * 150 // too vague to trust
              : 4 + _random.nextDouble() * 10,
        },
      );

      if (silent) {
        // Held back several ticks. Its event time stays now, so when it
        // lands it is genuinely late and must not overwrite newer state.
        _delayed.add((_tick + 3 + _random.nextInt(4), packet));
        continue;
      }

      packets.add(packet);
      // A retransmission the modem was not sure got through.
      if (_random.nextInt(12) == 0) packets.add(packet);
    }

    if (_timer == null) return;
    try {
      await _pipeline.ingest(packets);
    } catch (error) {
      // Ingestion can be interrupted if the simulator was stopped or the
      // database closed during shutdown/restart.
      if (_timer != null) {
        debugPrint('LiveSimulator ingestion error: $error');
      }
    }
  }
}
