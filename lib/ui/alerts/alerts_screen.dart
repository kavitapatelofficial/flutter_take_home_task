import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../widgets/common.dart';
import 'dismiss_sheet.dart';

class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(activeAlertsProvider);

    return switch (alerts.value) {
      null => const Center(child: CircularProgressIndicator()),
      final list when list.isEmpty => const EmptyState(
          icon: Icons.check_circle_outline,
          title: 'Nothing needs attention',
          detail: 'Alerts appear here while a condition is live and the '
              'signal behind it is fresh enough to trust.',
        ),
      final list => ListView.separated(
          itemCount: list.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => AlertTile(alert: list[i]),
        ),
    };
  }
}
