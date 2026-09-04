import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repo/vehicle_repository.dart';
import '../../domain/model/models.dart';
import '../alerts/dismiss_sheet.dart';
import '../widgets/common.dart';
import '../widgets/sparkline.dart';

class VehicleScreen extends ConsumerWidget {
  const VehicleScreen({super.key, required this.vehicleId});

  final String vehicleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(vehicleDetailProvider(vehicleId)).value;

    return Scaffold(
      appBar: AppBar(
        title: Text(detail?.regNo ?? 'Vehicle'),
        titleTextStyle: Theme.of(context).textTheme.titleMedium,
      ),
      body: detail == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _Header(detail),
                const SectionHeader('Readings'),
                _ReadingsRegister(detail.readings),
                _LastPingRow(detail),
                const SectionHeader('State of charge, last 24 hours'),
                _SocSection(vehicleId: vehicleId),
                const SectionHeader('Alerts'),
                _AlertsSection(vehicleId: vehicleId),
                const SectionHeader('Trips'),
                _TripsSection(vehicleId: vehicleId),
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.detail);

  final VehicleDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          StatusChip(detail.status),
          const SizedBox(width: 10),
          Text(
            detail.model,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const Spacer(),
          if (detail.currentGeofenceName != null)
            Row(
              children: [
                Icon(
                  Icons.place_outlined,
                  size: 15,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 3),
                Text(
                  detail.currentGeofenceName!,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// One row per signal, each carrying its own age and its own verdict.
///
/// The three-way split is the whole point of the screen. NORMAL and ALERT are
/// claims we can support because the reading is fresh. STALE is an admission
/// that we cannot see the signal right now and so will not claim either way --
/// it is not a quiet NORMAL. A signal that has never reported gets a dash and
/// no pill at all, because there is nothing yet to have an opinion about.
class _ReadingsRegister extends StatelessWidget {
  const _ReadingsRegister(this.readings);

  final List<SignalReading> readings;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (final reading in readings) _ReadingRow(reading),
        ],
      );
}

class _ReadingRow extends StatelessWidget {
  const _ReadingRow(this.reading);

  final SignalReading reading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stale = reading.verdict == ReadingVerdict.stale;
    final missing = reading.verdict == ReadingVerdict.missing;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(
        children: [
          SizedBox(
            width: 148,
            child: Text(reading.label, style: theme.textTheme.bodyMedium),
          ),
          Expanded(
            child: Text(
              missing
                  ? '—'
                  : _display(reading),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: stale || missing ? theme.colorScheme.outline : null,
              ),
            ),
          ),
          SizedBox(
            width: 78,
            child: Text(
              missing ? '' : formatAge(reading.age),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 62,
            child: Align(
              alignment: Alignment.centerRight,
              child: VerdictPill(reading.verdict),
            ),
          ),
        ],
      ),
    );
  }

  String _display(SignalReading reading) {
    if (reading.signal == 'ignition') {
      return reading.value == 1 ? 'On' : 'Off';
    }
    return formatValue(reading.value, reading.unit);
  }
}

/// Last ping is a vehicle-level fact, not a signal, so it sits below the
/// register with a rule above it rather than pretending to be another row.
class _LastPingRow extends StatelessWidget {
  const _LastPingRow(this.detail);

  final VehicleDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        const Divider(height: 20, indent: 16, endIndent: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(
            children: [
              SizedBox(
                width: 148,
                child: Text('Last ping', style: theme.textTheme.bodyMedium),
              ),
              Expanded(
                child: Text(
                  formatClock(detail.lastPing),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              Text(
                formatAge(detail.lastPingAge),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              const SizedBox(width: 72),
            ],
          ),
        ),
      ],
    );
  }
}

class _SocSection extends ConsumerWidget {
  const _SocSection({required this.vehicleId});

  final String vehicleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(socHistoryProvider(vehicleId)).value ?? const [];
    final readings = ref.watch(socReadingsProvider(vehicleId)).value ?? const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SocSparkline(history),
        ),
        const SizedBox(height: 8),
        // The table under the chart is deliberate: it shows that what is
        // plotted came out of an event log with individual timestamped rows,
        // rather than out of a running average someone kept in memory.
        if (readings.isNotEmpty)
          ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            title: Text(
              'Raw readings (${readings.length} most recent)',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            children: [
              for (final point in readings.take(30))
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          formatClock(point.at),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      Text(
                        '${point.value.toStringAsFixed(1)} %',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _AlertsSection extends ConsumerWidget {
  const _AlertsSection({required this.vehicleId});

  final String vehicleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(vehicleAlertsProvider(vehicleId)).value ?? const [];
    if (alerts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          'Nothing outstanding.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }
    return Column(
      children: [
        for (final alert in alerts) AlertTile(alert: alert, showVehicle: false),
      ],
    );
  }
}

class _TripsSection extends ConsumerWidget {
  const _TripsSection({required this.vehicleId});

  final String vehicleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trips = ref.watch(vehicleTripsProvider(vehicleId)).value ?? const [];
    final theme = Theme.of(context);

    if (trips.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          'No trips derived yet. Trips appear once the vehicle has been '
          'confirmed leaving a geofence.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      );
    }

    return Column(
      children: [
        for (final trip in trips.take(12))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            child: Row(
              children: [
                Icon(
                  trip.status == TripStatus.inProgress
                      ? Icons.local_shipping_outlined
                      : Icons.check_circle_outline,
                  size: 16,
                  color: trip.status == TripStatus.inProgress
                      ? const Color(0xFF3DD68C)
                      : theme.colorScheme.outline,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${trip.originName ?? 'Unknown'} → '
                        '${trip.destinationName ?? 'in progress'}',
                        style: theme.textTheme.bodyMedium,
                      ),
                      Row(
                        children: [
                          Text(
                            formatClock(trip.startedAt),
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.outline),
                          ),
                          // An uncertain boundary is surfaced, not smoothed
                          // over. The vehicle was in a basement and we know
                          // only that it left some time in a window.
                          if (trip.startUncertain || trip.endUncertain) ...[
                            const SizedBox(width: 6),
                            Tooltip(
                              message: 'A reporting gap straddles this trip’s '
                                  'boundary, so the time is when we found out, '
                                  'not when it happened.',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.help_outline,
                                    size: 12,
                                    color: theme.colorScheme.outline,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    'approximate',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.outline,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                Text(
                  trip.status == TripStatus.inProgress
                      ? 'ongoing'
                      : formatDuration(trip.duration),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
