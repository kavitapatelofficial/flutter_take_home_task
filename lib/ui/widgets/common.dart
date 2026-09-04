import 'package:flutter/material.dart';

import '../../domain/model/models.dart';
import '../../domain/model/vehicle_status.dart';

/// A duration as an operator would say it out loud.
///
/// Precision drops off as the number grows, because "4 minutes ago" is useful
/// and "4 minutes 37 seconds ago" is noise. Ages are the most-read text on
/// these screens; they have to be scannable.
String formatAge(Duration? age) {
  if (age == null) return 'never';
  final seconds = age.inSeconds;
  if (seconds < 5) return 'just now';
  if (seconds < 60) return '${seconds}s ago';
  if (age.inMinutes < 60) return '${age.inMinutes}m ago';
  if (age.inHours < 24) return '${age.inHours}h ${age.inMinutes % 60}m ago';
  return '${age.inDays}d ago';
}

String formatDuration(Duration? d) {
  if (d == null) return '—';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  return '${d.inHours}h ${d.inMinutes % 60}m';
}

String formatClock(DateTime? at) {
  if (at == null) return '—';
  final local = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String formatValue(double? value, String unit) {
  if (value == null) return '—';
  final text = value == value.roundToDouble() && value.abs() < 100000
      ? value.round().toString()
      : value.toStringAsFixed(1);
  return unit.isEmpty ? text : '$text $unit';
}

class StatusPalette {
  static Color of(VehicleStatus status, ColorScheme scheme) => switch (status) {
        VehicleStatus.moving => const Color(0xFF3DD68C),
        VehicleStatus.idle => const Color(0xFFF5C451),
        VehicleStatus.stopped => const Color(0xFF8A93A6),
        VehicleStatus.offline => const Color(0xFFE05C6E),
      };
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.dense = false});

  final VehicleStatus status;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = StatusPalette.of(status, Theme.of(context).colorScheme);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          color: color,
          fontSize: dense ? 10 : 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// The verdict pill in the readings register.
///
/// STALE is deliberately grey and deliberately not a judgement: it says we
/// cannot see the signal, not that the signal is fine. A missing signal gets
/// no pill at all, because there is nothing to say about a reading that has
/// never arrived.
class VerdictPill extends StatelessWidget {
  const VerdictPill(this.verdict, {super.key});

  final ReadingVerdict verdict;

  @override
  Widget build(BuildContext context) {
    if (verdict == ReadingVerdict.missing) return const SizedBox.shrink();

    final (label, color) = switch (verdict) {
      ReadingVerdict.normal => ('NORMAL', const Color(0xFF3DD68C)),
      ReadingVerdict.alert => ('ALERT', const Color(0xFFE05C6E)),
      ReadingVerdict.stale => ('STALE', const Color(0xFF8A93A6)),
      ReadingVerdict.missing => ('', Colors.transparent),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class SeverityDot extends StatelessWidget {
  const SeverityDot(this.severity, {super.key, this.size = 8});

  final AlertSeverity severity;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: severity == AlertSeverity.critical
              ? const Color(0xFFE05C6E)
              : const Color(0xFFF5C451),
        ),
      );
}

/// Small count badge used on the alert affordances.
class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key, required this.color});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Shown when a filter matches nothing.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 14),
            Text(title, style: theme.textTheme.titleMedium),
            if (detail != null) ...[
              const SizedBox(height: 6),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
            if (action != null) const SizedBox(height: 18),
            ?action,
          ],
        ),
      ),
    );
  }
}

/// A section heading with an optional trailing widget.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Row(
          children: [
            Text(
              title.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const Spacer(),
            ?trailing,
          ],
        ),
      );
}
