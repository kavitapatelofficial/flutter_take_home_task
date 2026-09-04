import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/model/models.dart';
import '../../domain/model/vehicle_status.dart';
import '../vehicle/vehicle_screen.dart';
import '../widgets/common.dart';

/// Fleet home: where are my vehicles, are they okay, what needs attention now.
class FleetScreen extends ConsumerWidget {
  const FleetScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehicles = ref.watch(fleetListProvider);
    final filter = ref.watch(fleetFilterProvider);

    return Column(
      children: [
        const _SearchField(),
        const _FilterChips(),
        const Divider(height: 1),
        Expanded(
          // .value rather than .when: Riverpod keeps the last result visible
          // while the next query is in flight, so the three-second refresh
          // does not flash a spinner over a list that is already correct.
          child: switch (vehicles.value) {
            null => const Center(child: CircularProgressIndicator()),
            final list when list.isEmpty => EmptyState(
                icon: Icons.filter_alt_off_outlined,
                title: 'No vehicles match',
                detail: filter.status == null
                    ? 'Nothing in the fleet matches "${filter.query}".'
                    : 'No vehicle is ${filter.status!.label.toLowerCase()}'
                        '${filter.query.isEmpty ? '' : ' and matches "${filter.query}"'}.',
                action: TextButton(
                  onPressed: () => ref.read(fleetFilterProvider.notifier).state =
                      const FleetFilter(),
                  child: const Text('Clear filters'),
                ),
              ),
            final list => ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) => _VehicleRow(list[i]),
              ),
          },
        ),
      ],
    );
  }
}

class _SearchField extends ConsumerWidget {
  const _SearchField();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: TextField(
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 20),
            hintText: 'Registration or model',
            border: OutlineInputBorder(),
          ),
          onChanged: (value) => ref.read(fleetFilterProvider.notifier).state =
              ref.read(fleetFilterProvider).copyWith(query: value),
        ),
      );
}

/// Filter chips with live counts.
///
/// The counts come from SQL over the same definition the list uses, so a chip
/// saying 42 and a list showing 41 is impossible by construction rather than
/// by care. They also respect the search box: filtering to a model and then
/// reading the chips tells you how that model is doing, which is the question
/// someone with a search box open is actually asking.
class _FilterChips extends ConsumerWidget {
  const _FilterChips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(fleetCountsProvider).value;
    final filter = ref.watch(fleetFilterProvider);

    Widget chip(String label, VehicleStatus? status, int? count, Color? color) {
      final selected = filter.status == status;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          selected: selected,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          side: color == null
              ? null
              : BorderSide(
                  color: color.withValues(alpha: selected ? 0.9 : 0.35),
                ),
          label: Text(
            count == null ? label : '$label  $count',
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? color : null,
            ),
          ),
          onSelected: (_) => ref.read(fleetFilterProvider.notifier).state =
              filter.copyWith(status: status, clearStatus: status == null),
        ),
      );
    }

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          chip('All', null, counts?.total, null),
          for (final status in VehicleStatus.values)
            chip(
              status.label[0] + status.label.substring(1).toLowerCase(),
              status,
              counts?[status],
              StatusPalette.of(status, Theme.of(context).colorScheme),
            ),
        ],
      ),
    );
  }
}

class _VehicleRow extends StatelessWidget {
  const _VehicleRow(this.vehicle);

  final FleetVehicle vehicle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final age = vehicle.lastPing == null
        ? null
        : DateTime.now().toUtc().difference(vehicle.lastPing!);

    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => VehicleScreen(vehicleId: vehicle.vehicleId),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        vehicle.regNo,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      StatusChip(vehicle.status, dense: true),
                      if (vehicle.openAlerts > 0) ...[
                        const SizedBox(width: 6),
                        SeverityDot(
                          vehicle.worstSeverity ?? AlertSeverity.warning,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${vehicle.openAlerts}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: vehicle.worstSeverity ==
                                    AlertSeverity.critical
                                ? const Color(0xFFE05C6E)
                                : const Color(0xFFF5C451),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${vehicle.model}  ·  ${formatAge(age)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            _SocReadout(soc: vehicle.soc, rangeKm: vehicle.rangeKm),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.outlineVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _SocReadout extends StatelessWidget {
  const _SocReadout({this.soc, this.rangeKm});

  final double? soc;
  final double? rangeKm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (soc) {
      null => theme.colorScheme.outline,
      final v when v < 10 => const Color(0xFFE05C6E),
      final v when v < 20 => const Color(0xFFF5C451),
      _ => theme.colorScheme.onSurface,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          soc == null ? '—' : '${soc!.round()}%',
          style: theme.textTheme.titleMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          rangeKm == null ? '—' : '${rangeKm!.round()} km',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
