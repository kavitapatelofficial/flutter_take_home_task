import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/model/models.dart';
import '../vehicle/vehicle_screen.dart';
import '../widgets/common.dart';

/// One alert, with the dismissal affordance.
class AlertTile extends ConsumerWidget {
  const AlertTile({
    super.key,
    required this.alert,
    this.showVehicle = true,
  });

  final FleetAlert alert;
  final bool showVehicle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final critical = alert.severity == AlertSeverity.critical;
    final color =
        critical ? const Color(0xFFE05C6E) : const Color(0xFFF5C451);

    return InkWell(
      onTap: showVehicle
          ? () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => VehicleScreen(vehicleId: alert.vehicleId),
                ),
              )
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            SeverityDot(alert.severity, size: 9),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        alert.title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: color,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        alert.detail,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    showVehicle
                        ? '${alert.regNo}  ·  since ${formatClock(alert.openedAt)}'
                        : 'Since ${formatClock(alert.openedAt)}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => dismissAlert(context, ref, alert),
              child: const Text('Dismiss'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The dismissal flow: reason sheet, then a five-second window to take it back.
///
/// Dismissal is not deletion. It hides the alert from the operator's list and
/// records who said what, while the underlying condition stays open — so the
/// alert comes back on its own if the condition clears and returns, and the
/// Diagnostics screen can still show how many open conditions have been waved
/// away.
Future<void> dismissAlert(
  BuildContext context,
  WidgetRef ref,
  FleetAlert alert,
) async {
  final reason = await showModalBottomSheet<DismissReason>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(
              alert.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              '${alert.regNo} · ${alert.detail}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ),
          // Order is fixed by the spec, and it is the right order anyway:
          // the common case first, the correction second, the escape hatch
          // last.
          for (final option in DismissReason.values)
            ListTile(
              dense: true,
              title: Text(option.label),
              onTap: () => Navigator.of(context).pop(option),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  if (reason == null || !context.mounted) return;

  final services = ref.read(servicesProvider);
  await services.pipeline.alerts.dismiss(alert.alertId, reason.name);
  services.pipeline.notifyChanged();

  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 5),
        content: Text('${alert.title} dismissed · ${reason.label}'),
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () async {
            await services.pipeline.alerts.undoDismiss(alert.alertId);
            services.pipeline.notifyChanged();
          },
        ),
      ),
    );
}
