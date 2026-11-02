import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../core/domain.dart';
import '../../data/models.dart';

class LabPoint {
  const LabPoint({required this.hours, required this.value});
  final double hours;
  final double value;
}

/// Line chart for a modelled concentration, drawn with a custom painter so it
/// stays crisp at any density and needs no charting dependency.
class LevelChart extends StatefulWidget {
  const LevelChart({
    super.key,
    required this.points,
    required this.windowStart,
    required this.windowEnd,
    required this.low,
    required this.high,
    required this.unit,
    this.labs = const [],
    this.height = 220,
    this.showNow = true,
    this.now,
    this.compare,
    this.compareLabel,
  });

  final List<Offset> points;
  final double windowStart;
  final double windowEnd;
  final double low;
  final double high;
  final String unit;
  final List<LabPoint> labs;
  final double height;
  final bool showNow;

  /// Current time in hours since the epoch. The painter marks it with a dashed
  /// line and a dot, which is what makes a live reading visibly live.
  final double? now;

  /// A second curve, e.g. the planned regimen on the forecast screen.
  final List<Offset>? compare;
  final String? compareLabel;

  @override
  State<LevelChart> createState() => _LevelChartState();
}

class _LevelChartState extends State<LevelChart> {
  double? _scrubHours;

  ({double hours, double value})? _valueAt(double hours, List<Offset> points) {
    if (points.isEmpty) return null;
    if (hours <= points.first.dx)
      return (hours: points.first.dx, value: points.first.dy);
    if (hours >= points.last.dx)
      return (hours: points.last.dx, value: points.last.dy);
    var lo = 0;
    var hi = points.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) ~/ 2;
      if (points[mid].dx <= hours) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = points[lo];
    final b = points[hi];
    if (b.dx == a.dx) return (hours: a.dx, value: a.dy);
    final t = (hours - a.dx) / (b.dx - a.dx);
    return (hours: hours, value: a.dy + (b.dy - a.dy) * t);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final all = [
      ...widget.points,
      if (widget.compare != null) ...widget.compare!,
    ];
    if (all.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: Text(
            '—',
            style: textTheme.titleMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    final scrub = _scrubHours == null
        ? null
        : _valueAt(_scrubHours!, widget.points);
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => setState(
              () => _scrubHours = _hoursFor(d.localPosition.dx, width),
            ),
            onHorizontalDragStart: (d) => setState(
              () => _scrubHours = _hoursFor(d.localPosition.dx, width),
            ),
            onHorizontalDragUpdate: (d) => setState(
              () => _scrubHours = _hoursFor(d.localPosition.dx, width),
            ),
            onHorizontalDragEnd: (_) => setState(() => _scrubHours = null),
            onTapCancel: () => setState(() => _scrubHours = null),
            child: CustomPaint(
              painter: _ChartPainter(
                points: widget.points,
                compare: widget.compare,
                labs: widget.labs,
                windowStart: widget.windowStart,
                windowEnd: widget.windowEnd,
                low: widget.low,
                high: widget.high,
                unit: widget.unit,
                line: scheme.primary,
                compareColor: scheme.tertiary,
                band: scheme.primary.withValues(alpha: 0.09),
                grid: scheme.outlineVariant.withValues(alpha: 0.5),
                axis: scheme.onSurfaceVariant,
                labelStyle:
                    textTheme.labelSmall ?? const TextStyle(fontSize: 11),
                nowLabel: 'now',
                nowHours: widget.showNow ? widget.now : null,
                scrub: scrub,
                scrubColor: scheme.onSurface,
                compareLabel: widget.compareLabel,
                textDirection: Directionality.of(context),
              ),
              size: Size(width, widget.height),
            ),
          );
        },
      ),
    );
  }

  double _hoursFor(double dx, double width) {
    final chartLeft = 44.0;
    final chartRight = width - 12.0;
    final ratio = ((dx - chartLeft) / (chartRight - chartLeft)).clamp(0.0, 1.0);
    return widget.windowStart + ratio * (widget.windowEnd - widget.windowStart);
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.points,
    required this.compare,
    required this.labs,
    required this.windowStart,
    required this.windowEnd,
    required this.low,
    required this.high,
    required this.unit,
    required this.line,
    required this.compareColor,
    required this.band,
    required this.grid,
    required this.axis,
    required this.labelStyle,
    required this.nowLabel,
    required this.nowHours,
    required this.scrub,
    required this.scrubColor,
    required this.compareLabel,
    required this.textDirection,
  });

  final List<Offset> points;
  final List<Offset>? compare;
  final List<LabPoint> labs;
  final double windowStart;
  final double windowEnd;
  final double low;
  final double high;
  final String unit;
  final Color line;
  final Color compareColor;
  final Color band;
  final Color grid;
  final Color axis;
  final TextStyle labelStyle;
  final String nowLabel;
  final double? nowHours;
  final ({double hours, double value})? scrub;
  final Color scrubColor;
  final String? compareLabel;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 44.0;
    const right = 12.0;
    const top = 14.0;
    const bottom = 26.0;
    final rect = Rect.fromLTRB(
      left,
      top,
      size.width - right,
      size.height - bottom,
    );
    if (rect.width <= 0 || rect.height <= 0) return;

    final values = <double>[
      for (final p in points)
        if (p.dx >= windowStart && p.dx <= windowEnd) p.dy,
      if (compare != null)
        for (final p in compare!)
          if (p.dx >= windowStart && p.dx <= windowEnd) p.dy,
      for (final l in labs) l.value,
      low,
      high,
    ];
    if (values.isEmpty) return;
    var maxV = values.reduce(math.max);
    var minV = values.reduce(math.min);
    maxV = math.max(maxV, high * 1.15);
    minV = math.max(0, minV * 0.85);
    if (maxV - minV < 1e-6) maxV = minV + 1;

    double xFor(double hours) =>
        rect.left +
        ((hours - windowStart) / (windowEnd - windowStart)).clamp(0.0, 1.0) *
            rect.width;
    double yFor(double v) =>
        rect.bottom - ((v - minV) / (maxV - minV)) * rect.height;

    // Target band.
    final bandRect = Rect.fromLTRB(
      rect.left,
      yFor(high),
      rect.right,
      yFor(low),
    );
    canvas.drawRect(bandRect, Paint()..color = band);

    // Horizontal grid + y labels.
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    final labelPainter = TextPainter(textDirection: textDirection);
    for (var i = 0; i <= 3; i++) {
      final v = minV + (maxV - minV) * i / 3;
      final y = yFor(v);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), gridPaint);
      labelPainter.text = TextSpan(
        text: v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1),
        style: labelStyle.copyWith(color: axis),
      );
      labelPainter.layout();
      labelPainter.paint(
        canvas,
        Offset(rect.left - labelPainter.width - 6, y - labelPainter.height / 2),
      );
    }

    // Time axis labels.
    final span = windowEnd - windowStart;
    final days = span / 24;
    final steps = days <= 2 ? 4 : (days <= 10 ? 5 : 4);
    for (var i = 0; i <= steps; i++) {
      final h = windowStart + span * i / steps;
      final label = days <= 2
          ? DateFormat.Hm().format(dateTimeFromHours(h))
          : DateFormat.Md().format(dateTimeFromHours(h));
      labelPainter.text = TextSpan(
        text: label,
        style: labelStyle.copyWith(color: axis),
      );
      labelPainter.layout();
      final x = xFor(h);
      labelPainter.paint(
        canvas,
        Offset(
          (x - labelPainter.width / 2).clamp(
            rect.left,
            rect.right - labelPainter.width,
          ),
          rect.bottom + 8,
        ),
      );
    }

    if (compare != null) {
      final path = _pathFor(compare!, xFor, yFor, windowStart, windowEnd);
      canvas.drawPath(
        path,
        Paint()
          ..color = compareColor.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }

    // Curve with a soft fill below it.
    final path = _pathFor(points, xFor, yFor, windowStart, windowEnd);
    final fill = Path.from(path)
      ..lineTo(xFor(points.last.dx.clamp(windowStart, windowEnd)), rect.bottom)
      ..lineTo(xFor(points.first.dx.clamp(windowStart, windowEnd)), rect.bottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, rect.top),
          Offset(0, rect.bottom),
          [line.withValues(alpha: 0.18), line.withValues(alpha: 0.01)],
        ),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Everything after now is a projection, so it is drawn dashed: the same
    // visual language the original chart used for its prediction curve.
    if (nowHours != null && nowHours! > windowStart && nowHours! < windowEnd) {
      final future = _pathFor(points, xFor, yFor, nowHours!, windowEnd);
      final start = _valueAtHours(points, nowHours!);
      final rest = Path();
      if (start != null) {
        rest.moveTo(xFor(nowHours!), yFor(start));
        rest.addPath(future, Offset.zero);
      } else {
        rest.addPath(future, Offset.zero);
      }
      _dashPath(
        canvas,
        rest,
        Paint()
          ..color = line.withValues(alpha: 0.75)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }

    // Lab results.
    for (final lab in labs) {
      if (lab.hours < windowStart || lab.hours > windowEnd) continue;
      final center = Offset(xFor(lab.hours), yFor(lab.value));
      canvas.drawCircle(center, 5, Paint()..color = Colors.white);
      canvas.drawCircle(
        center,
        5,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    // The live position: a dashed drop line and a dot on the curve.
    final live = nowHours;
    if (live != null && live >= windowStart && live <= windowEnd) {
      final x = xFor(live);
      final dash = Paint()
        ..color = axis.withValues(alpha: 0.45)
        ..strokeWidth = 1;
      var y = rect.top;
      while (y < rect.bottom) {
        canvas.drawLine(
          Offset(x, y),
          Offset(x, math.min(y + 4, rect.bottom)),
          dash,
        );
        y += 8;
      }
      final point = _valueAtHours(points, live);
      if (point != null) {
        canvas.drawCircle(Offset(x, yFor(point)), 3.5, Paint()..color = line);
      }
    }

    if (scrub != null) {
      final x = xFor(scrub!.hours);
      canvas.drawLine(
        Offset(x, rect.top),
        Offset(x, rect.bottom),
        Paint()
          ..color = scrubColor.withValues(alpha: 0.3)
          ..strokeWidth = 1,
      );
      final y = yFor(scrub!.value);
      canvas.drawCircle(Offset(x, y), 4, Paint()..color = scrubColor);
      final text =
          '${scrub!.value.toStringAsFixed(scrub!.value >= 100 ? 0 : 1)} $unit';
      labelPainter.text = TextSpan(
        text: text,
        style: labelStyle.copyWith(
          color: scrubColor,
          fontWeight: FontWeight.w600,
        ),
      );
      labelPainter.layout();
      final boxWidth = labelPainter.width + 14;
      final boxLeft = (x - boxWidth / 2).clamp(
        rect.left,
        rect.right - boxWidth,
      );
      final boxRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(boxLeft, rect.top, boxWidth, labelPainter.height + 8),
        const Radius.circular(6),
      );
      canvas.drawRRect(boxRect, Paint()..color = grid.withValues(alpha: 0.9));
      labelPainter.paint(canvas, Offset(boxLeft + 7, rect.top + 4));
    }
  }

  /// Dashes a path by walking its metrics, so curves stay smooth.
  void _dashPath(Canvas canvas, Path path, Paint paint) {
    const dash = 5.0;
    const gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  double? _valueAtHours(List<Offset> pts, double hours) {
    final visible = pts
        .where((p) => p.dx >= windowStart && p.dx <= windowEnd)
        .toList();
    if (visible.isEmpty) return null;
    if (hours <= visible.first.dx) return visible.first.dy;
    if (hours >= visible.last.dx) return visible.last.dy;
    for (var i = 0; i < visible.length - 1; i++) {
      final a = visible[i];
      final b = visible[i + 1];
      if (hours >= a.dx && hours <= b.dx) {
        if (b.dx == a.dx) return a.dy;
        final t = (hours - a.dx) / (b.dx - a.dx);
        return a.dy + (b.dy - a.dy) * t;
      }
    }
    return visible.last.dy;
  }

  Path _pathFor(
    List<Offset> pts,
    double Function(double) xFor,
    double Function(double) yFor,
    double start,
    double end,
  ) {
    final path = Path();
    final visible = pts.where((p) => p.dx >= start && p.dx <= end).toList();
    if (visible.isEmpty) return path;
    path.moveTo(xFor(visible.first.dx), yFor(visible.first.dy));
    for (var i = 0; i < visible.length - 1; i++) {
      final p0 = visible[i];
      final p1 = visible[i + 1];
      final x0 = xFor(p0.dx);
      final y0 = yFor(p0.dy);
      final x1 = xFor(p1.dx);
      final y1 = yFor(p1.dy);
      final midX = (x0 + x1) / 2;
      path.cubicTo(midX, y0, midX, y1, x1, y1);
    }
    return path;
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.points != points ||
      old.compare != compare ||
      old.labs != labs ||
      old.windowStart != windowStart ||
      old.windowEnd != windowEnd ||
      old.nowHours != nowHours ||
      old.scrub != scrub;
}

/// Compact sparkline used in list rows.
class MiniCurve extends StatelessWidget {
  const MiniCurve({
    super.key,
    required this.points,
    this.color,
    this.height = 36,
  });

  final List<double> points;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (points.isEmpty) return SizedBox(height: height);
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _SparkPainter(points, color ?? scheme.primary),
        size: Size.infinite,
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color);
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final maxV = values.reduce(math.max);
    final minV = values.reduce(math.min);
    final span = (maxV - minV).abs() < 1e-6 ? 1.0 : maxV - minV;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y =
          size.height - ((values[i] - minV) / span) * (size.height - 4) - 2;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values || old.color != color;
}

/// Small helper for a "day" heatmap of dose counts.
class DoseHeatmap extends StatelessWidget {
  const DoseHeatmap({super.key, required this.counts, required this.weeks});

  final Map<int, int> counts;
  final int weeks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final today = localDay(DateTime.now());
    final start = today - weeks * 7 + 1;
    final maxCount = counts.values.isEmpty ? 1 : counts.values.reduce(math.max);
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 3.0;
        final cell = (constraints.maxWidth - gap * (weeks - 1)) / weeks;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var w = 0; w < weeks; w++)
              Column(
                children: [
                  for (var d = 0; d < 7; d++)
                    Builder(
                      builder: (context) {
                        final day = start + w * 7 + d;
                        final count = counts[day] ?? 0;
                        final intensity = count == 0
                            ? 0.0
                            : (0.25 + 0.75 * count / maxCount);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: gap),
                          child: Container(
                            width: cell,
                            height: cell,
                            decoration: BoxDecoration(
                              color: count == 0
                                  ? scheme.surfaceContainerHighest
                                  : scheme.primary.withValues(alpha: intensity),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}
