import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/model/models.dart';
import '../widgets/common.dart';

class GeofencesScreen extends ConsumerWidget {
  const GeofencesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fences = ref.watch(geofencesProvider).value;

    return Scaffold(
      body: switch (fences) {
        null => const Center(child: CircularProgressIndicator()),
        final list when list.isEmpty => const EmptyState(
            icon: Icons.fence_outlined,
            title: 'No geofences',
            detail: 'Add one to start deriving trips.',
          ),
        final list => ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _FenceRow(list[i]),
          ),
      },
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editFence(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('Geofence'),
      ),
    );
  }
}

class _FenceRow extends ConsumerWidget {
  const _FenceRow(this.fence);

  final Geofence fence;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: () => _editFence(context, ref, fence),
      title: Row(
        children: [
          Text(
            fence.name,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: fence.active ? null : theme.colorScheme.outline,
            ),
          ),
          const SizedBox(width: 8),
          if (!fence.active)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Text(
                'INACTIVE',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(
        '${fence.radiusM.round()} m radius  ·  v${fence.version}  ·  '
        '${fence.lat.toStringAsFixed(4)}, ${fence.lon.toStringAsFixed(4)}',
        style: theme.textTheme.bodySmall,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '${fence.vehicleCount}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: fence.vehicleCount > 0
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
          ),
          Text('inside', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Create or edit. An edit supersedes the current version rather than mutating
/// it, so history keeps reading against the fence that was actually in force
/// at the time — and the fleet is re-derived afterwards, because changing a
/// fence changes what it means from now on for every vehicle.
Future<void> _editFence(
  BuildContext context,
  WidgetRef ref,
  Geofence? existing,
) async {
  final nameController = TextEditingController(text: existing?.name ?? '');
  final latController =
      TextEditingController(text: existing?.lat.toStringAsFixed(5) ?? '12.9716');
  final lonController =
      TextEditingController(text: existing?.lon.toStringAsFixed(5) ?? '77.5946');
  final radiusController =
      TextEditingController(text: (existing?.radiusM ?? 400).round().toString());

  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(existing == null ? 'New geofence' : 'Edit ${existing.name}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: latController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(labelText: 'Latitude'),
            ),
            TextField(
              controller: lonController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(labelText: 'Longitude'),
            ),
            TextField(
              controller: radiusController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Radius (metres)'),
            ),
            if (existing != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  'Editing creates version ${existing.version + 1}. Crossings '
                  'already derived against earlier versions are left alone.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (existing != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: Text(existing.active ? 'Deactivate' : 'Reactivate'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Save'),
        ),
      ],
    ),
  );

  if (!context.mounted) return;
  final services = ref.read(servicesProvider);

  if (saved == null && existing != null) {
    // The deactivate/reactivate button. A new version with the flag flipped;
    // the fence and everything derived from it stay on the record.
    await services.geofences.setActive(
      existing.geofenceId,
      active: !existing.active,
    );
  } else if (saved ?? false) {
    final name = nameController.text.trim();
    final lat = double.tryParse(latController.text);
    final lon = double.tryParse(lonController.text);
    final radius = double.tryParse(radiusController.text);
    if (name.isEmpty || lat == null || lon == null || radius == null) return;

    if (existing == null) {
      await services.geofences.create(
        name: name,
        lat: lat,
        lon: lon,
        radiusM: radius,
      );
    } else {
      await services.geofences.edit(
        existing.geofenceId,
        name: name,
        lat: lat,
        lon: lon,
        radiusM: radius,
      );
    }
  } else {
    return;
  }

  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Re-deriving crossings and trips…')),
  );
  await services.pipeline.recomputeFleet();
}
