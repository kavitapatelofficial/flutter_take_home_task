import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/services.dart';
import '../widgets/common.dart';

/// The scale exercise, runnable on the device it is being measured on.
///
/// A benchmark that only runs on a developer laptop measures the wrong
/// machine. These buttons build the 500-vehicle dataset in place and time the
/// same queries the fleet screen uses, so the numbers in the README are the
/// device's numbers.
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  final _log = <String>[];
  bool _busy = false;

  void _say(String line) => setState(() => _log.insert(0, line));

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _say('error: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runBackfill() => _guard(() async {
        final services = ref.read(servicesProvider);
        _say('Backfilling 500 vehicles...');
        final report = await services.backfill.run(
          onStage: (stage) => _say('  $stage'),
        );
        _say('$report');

        _say('Deriving crossings and trips for the fleet...');
        final started = DateTime.now();
        await services.pipeline.recomputeFleet();
        _say('  derivation: '
            '${DateTime.now().difference(started).inMilliseconds} ms');

        await services.pipeline.alerts.evaluate();
        services.pipeline.notifyChanged();
      });

  /// Times the fleet query the way the screen actually issues it.
  Future<void> _measure() => _guard(() async {
        final services = ref.read(servicesProvider);
        final rows = await services.fleet.list();
        _say('Measuring over ${rows.length} vehicles...');

        Future<List<double>> time(Future<void> Function() call) async {
          // A few unmeasured passes first: the first execution of a query
          // pays for planning, and reporting that as the steady-state number
          // would be dishonest in the flattering direction as soon as anyone
          // looked twice.
          for (var i = 0; i < 5; i++) {
            await call();
          }
          final samples = <double>[];
          for (var i = 0; i < 50; i++) {
            final sw = Stopwatch()..start();
            await call();
            sw.stop();
            samples.add(sw.elapsedMicroseconds / 1000);
          }
          return samples..sort();
        }

        String p(List<double> s, int pct) =>
            s[((pct / 100) * (s.length - 1)).round()].toStringAsFixed(1);

        final list = await time(() => services.fleet.list());
        _say('fleet list   p50 ${p(list, 50)} ms   p95 ${p(list, 95)} ms');

        final counts = await time(() => services.fleet.counts());
        _say('chip counts  p50 ${p(counts, 50)} ms   p95 ${p(counts, 95)} ms');
      });

  Future<void> _compact() => _guard(() async {
        final services = ref.read(servicesProvider);
        _say('Compacting...');
        final report = await services.retention.compact();
        _say('dropped ${report.rowsDropped} raw rows, '
            '${report.rollupRows} rollup buckets remain');
        services.pipeline.notifyChanged();
      });

  @override
  Widget build(BuildContext context) {
    final services = ref.watch(servicesProvider);
    final stats = ref.watch(_dbStatsProvider).value;

    return ListView(
      children: [
        const SectionHeader('This device'),
        _Stat('Cold start to a queryable database',
            '${services.startupMillis} ms'),
        _Stat('Database file', services.db.path),
        if (stats != null) ...[
          _Stat('Signal rows', '${stats.signalRows}'),
          _Stat('Rollup buckets', '${stats.rollupRows}'),
          _Stat('Vehicles', '${stats.vehicles}'),
          _Stat('Crossings / trips', '${stats.crossings} / ${stats.trips}'),
          _Stat('Open conditions dismissed', '${stats.dismissed}'),
          _Stat('Packets refused at ingest', '${stats.rejected}'),
        ],
        const SectionHeader('Live telemetry'),
        SwitchListTile(
          value: services.simulator.isRunning,
          title: const Text('Simulator'),
          subtitle: const Text(
            'Emits packets every few seconds, including duplicates, late '
            'deliveries and basement backlogs.',
          ),
          onChanged: (on) => setState(() {
            on ? services.simulator.start() : services.simulator.stop();
          }),
        ),
        const SectionHeader('Scale exercise'),
        _Action(
          label: 'Backfill 500 vehicles (2.6M signal rows)',
          onPressed: _busy ? null : _runBackfill,
        ),
        _Action(
          label: 'Measure fleet query (p50 / p95, warm)',
          onPressed: _busy ? null : _measure,
        ),
        _Action(
          label: 'Run retention compaction',
          onPressed: _busy ? null : _compact,
        ),
        _Action(
          label: 'Delete the database and restart',
          destructive: true,
          onPressed: _busy
              ? null
              : () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Delete the database?'),
                      content: const Text(
                        'Every stored packet, trip and alert goes. The app '
                        'closes its connection first; relaunch to start over.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (ok ?? false) {
                    services.simulator.stop();
                    await services.db.close();
                    await AppServices.deleteDatabaseFile();
                    _say('Database deleted. Restart the app.');
                  }
                },
        ),
        if (_busy) const LinearProgressIndicator(),
        const SectionHeader('Log'),
        for (final line in _log)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
            child: Text(
              line,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
            ),
          ),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
            ),
          ],
        ),
      );
}

class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: onPressed,
            style: destructive
                ? OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            child: Text(label),
          ),
        ),
      );
}

class _DbStats {
  const _DbStats({
    required this.signalRows,
    required this.rollupRows,
    required this.vehicles,
    required this.crossings,
    required this.trips,
    required this.dismissed,
    required this.rejected,
  });

  final int signalRows;
  final int rollupRows;
  final int vehicles;
  final int crossings;
  final int trips;
  final int dismissed;
  final int rejected;
}

final _dbStatsProvider = FutureProvider<_DbStats>((ref) async {
  ref.watch(refreshTickProvider);
  final services = ref.watch(servicesProvider);
  Future<int> count(String table) async =>
      (await services.db.selectOne('SELECT count(*) AS n FROM $table'))!['n']
          as int;

  return _DbStats(
    signalRows: await count('signal_readings'),
    rollupRows: await count('signal_rollups'),
    vehicles: await count('vehicles'),
    crossings: await count('geofence_events'),
    trips: await count('trips'),
    dismissed: await services.alerts.dismissedCount(),
    rejected: await count('rejected_packets'),
  );
});
