import 'package:flutter/material.dart';

import '../../domain/model/models.dart';
import '../../domain/rules.dart';

/// SOC over the retained window.
///
/// Hand-drawn rather than pulled from a charting package: it is one polyline
/// and two threshold rules, and a dependency would cost more to justify than
/// to replace. The threshold lines are the point of the chart -- an operator
/// wants to see how close to 20% a truck ran, not admire a curve.
class SocSparkline extends StatelessWidget {
  const SocSparkline(this.points, {super.key, this.height = 120});

  final List<HistoryPoint> points;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            points.isEmpty
                ? 'No state of charge history in the retained window'
                : 'Only one reading so far',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      );
    }

    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparklinePainter(
          points: points,
          line: Theme.of(context).colorScheme.primary,
          grid: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.points,
    required this.line,
    required this.grid,
  });

  final List<HistoryPoint> points;
  final Color line;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    // The y axis is pinned to 0..100 rather than fitted to the data, because a
    // chart that rescales every refresh cannot be compared against itself, and
    // "how close to the threshold" is the whole question.
    double y(double soc) => size.height - (soc.clamp(0, 100) / 100) * size.height;

    final firstAt = points.first.at.millisecondsSinceEpoch;
    final lastAt = points.last.at.millisecondsSinceEpoch;
    final span = (lastAt - firstAt).clamp(1, 1 << 62);
    double x(DateTime at) =>
        ((at.millisecondsSinceEpoch - firstAt) / span) * size.width;

    for (final (threshold, color) in [
      (Rules.socWarningBelow, const Color(0xFFF5C451)),
      (Rules.socCriticalBelow, const Color(0xFFE05C6E)),
    ]) {
      final paint = Paint()
        ..color = color.withValues(alpha: 0.45)
        ..strokeWidth = 1;
      const dash = 5.0;
      for (var dx = 0.0; dx < size.width; dx += dash * 2) {
        canvas.drawLine(
          Offset(dx, y(threshold)),
          Offset((dx + dash).clamp(0, size.width), y(threshold)),
          paint,
        );
      }
    }

    final path = Path()..moveTo(x(points.first.at), y(points.first.value));
    for (final point in points.skip(1)) {
      path.lineTo(x(point.at), y(point.value));
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeJoin = StrokeJoin.round,
    );

    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(x(points.first.at), size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = line.withValues(alpha: 0.10));
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => old.points != points;
}
