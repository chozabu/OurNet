import 'dart:math';

import 'package:flutter/material.dart';

/// Sizes the way the stats screens show them: 1.2 MB, 340 KB, 12 B.
String sizeText(num bytes) {
  if (bytes < 1024) return '${bytes.round()} B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024, i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : v >= 10 ? 1 : 2)} ${units[i]}';
}

String rateText(double bytesPerSecond) => '${sizeText(bytesPerSecond)}/s';

String countText(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

String percentText(double fraction) {
  final p = fraction * 100;
  return p > 0 && p < 1 ? '<1%' : '${p.round()}%';
}

String durationText(Duration d) {
  if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inSeconds}s';
}

/// Colours that stay apart for most kinds of colour vision, light or dark.
class StatColors {
  final Color download, upload, track;
  final List<Color> series;
  const StatColors._(this.download, this.upload, this.track, this.series);

  factory StatColors.of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final track = Theme.of(context).colorScheme.surfaceContainerHighest;
    return dark
        ? StatColors._(
            const Color(0xFF2DD4BF),
            const Color(0xFFFBBF24),
            track,
            const [
              Color(0xFF2DD4BF),
              Color(0xFFFBBF24),
              Color(0xFF818CF8),
              Color(0xFFF472B6),
              Color(0xFF60A5FA),
              Color(0xFFA3E635),
              Color(0xFFFB923C),
              Color(0xFF94A3B8),
            ],
          )
        : StatColors._(
            const Color(0xFF0F766E),
            const Color(0xFFB45309),
            track,
            const [
              Color(0xFF0F766E),
              Color(0xFFB45309),
              Color(0xFF4F46E5),
              Color(0xFFBE185D),
              Color(0xFF1D4ED8),
              Color(0xFF4D7C0F),
              Color(0xFFC2410C),
              Color(0xFF64748B),
            ],
          );
  }
}

/// A titled block on a stats screen.
class StatSection extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  const StatSection({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 14),
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                ?trailing,
              ],
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

/// A large number with a caption, for rows of headline figures.
class Figure extends StatelessWidget {
  final String value, label;
  final Color? color;
  final IconData? icon;
  const Figure({super.key, required this.value, required this.label, this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: color ?? theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                value,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Figures laid out in a wrapping grid, two or more to a row.
class FigureGrid extends StatelessWidget {
  final List<Widget> children;
  const FigureGrid(this.children, {super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final columns = max(2, (box.maxWidth / 150).floor());
      final width = (box.maxWidth - (columns - 1) * 12) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 14,
        children: [for (final c in children) SizedBox(width: width, child: c)],
      );
    },
  );
}

class LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  final String? value;
  const LegendDot({super.key, required this.color, required this.label, this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 6),
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)),
        if (value != null) ...[
          const SizedBox(width: 6),
          Text(
            value!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

/// A row with a label, a proportional bar and a value.
class BarRow extends StatelessWidget {
  final String label;
  final String value;
  final String? detail;
  final double fraction;
  final Color color;
  const BarRow({
    super.key,
    required this.label,
    required this.value,
    required this.fraction,
    required this.color,
    this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
              Text(
                value,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction.clamp(0.0, 1.0).toDouble(),
              minHeight: 6,
              color: color,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                detail!,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

/// One horizontal bar split into proportional segments.
class SegmentedBar extends StatelessWidget {
  final List<({double value, Color color})> segments;
  final double? total;
  final double height;

  /// Marks on the bar as fractions of [total], such as a warning level.
  final List<double> marks;
  const SegmentedBar({
    super.key,
    required this.segments,
    this.total,
    this.height = 16,
    this.marks = const [],
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.fromHeight(height),
    painter: _SegmentedPainter(
      segments,
      total ?? segments.fold<double>(0, (s, e) => s + e.value),
      Theme.of(context).colorScheme.surfaceContainerHighest,
      Theme.of(context).colorScheme.onSurface,
      marks,
    ),
  );
}

class _SegmentedPainter extends CustomPainter {
  final List<({double value, Color color})> segments;
  final double total;
  final Color track, mark;
  final List<double> marks;
  _SegmentedPainter(this.segments, this.total, this.track, this.mark, this.marks);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, r);
    canvas.drawRRect(rrect, Paint()..color = track);
    if (total <= 0) return;
    canvas.save();
    canvas.clipRRect(rrect);
    var x = 0.0;
    for (final s in segments) {
      final w = size.width * (s.value / total).clamp(0.0, 1.0);
      if (w <= 0) continue;
      // A hairline gap keeps neighbours apart without a border.
      canvas.drawRect(Rect.fromLTWH(x, 0, max(0, w - 1.5), size.height), Paint()..color = s.color);
      x += w;
    }
    canvas.restore();
    for (final m in marks) {
      final mx = size.width * m.clamp(0.0, 1.0);
      canvas.drawRect(
        Rect.fromLTWH(mx - 1, -2, 2, size.height + 4),
        Paint()..color = mark.withValues(alpha: 0.7),
      );
    }
  }

  @override
  bool shouldRepaint(_SegmentedPainter old) => true;
}

/// Mirrored live chart: download above the axis, upload below.
class RateChart extends StatelessWidget {
  final List<double> down, up;
  final int length;
  final double height;
  final Color downColor, upColor;
  const RateChart({
    super.key,
    required this.down,
    required this.up,
    required this.length,
    required this.downColor,
    required this.upColor,
    this.height = 150,
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.fromHeight(height),
    painter: _RatePainter(
      down,
      up,
      length,
      downColor,
      upColor,
      Theme.of(context).colorScheme.outlineVariant,
    ),
  );
}

class _RatePainter extends CustomPainter {
  final List<double> down, up;
  final int length;
  final Color downColor, upColor, grid;
  _RatePainter(this.down, this.up, this.length, this.downColor, this.upColor, this.grid);

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final peak = max(4096.0, [...down, ...up].fold<double>(0, max) * 1.15);
    final axis = Paint()
      ..color = grid
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), axis);
    for (final f in [0.5]) {
      canvas.drawLine(
        Offset(0, mid - mid * f),
        Offset(size.width, mid - mid * f),
        Paint()..color = grid.withValues(alpha: 0.3),
      );
      canvas.drawLine(
        Offset(0, mid + mid * f),
        Offset(size.width, mid + mid * f),
        Paint()..color = grid.withValues(alpha: 0.3),
      );
    }
    void draw(List<double> values, Color color, double sign) {
      if (values.isEmpty) return;
      final step = size.width / max(1, length - 1);
      final offset = length - values.length;
      Offset point(int i) => Offset(
        (offset + i) * step,
        mid - sign * (values[i] / peak).clamp(0.0, 1.0) * (mid - 4),
      );
      final line = Path()..moveTo(point(0).dx, point(0).dy);
      for (var i = 1; i < values.length; i++) {
        final a = point(i - 1), b = point(i);
        final cx = (a.dx + b.dx) / 2;
        line.cubicTo(cx, a.dy, cx, b.dy, b.dx, b.dy);
      }
      final area = Path.from(line)
        ..lineTo(point(values.length - 1).dx, mid)
        ..lineTo(point(0).dx, mid)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: sign > 0 ? Alignment.topCenter : Alignment.bottomCenter,
            end: sign > 0 ? Alignment.bottomCenter : Alignment.topCenter,
            colors: [color.withValues(alpha: 0.45), color.withValues(alpha: 0.03)],
          ).createShader(Offset.zero & size),
      );
      canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round,
      );
    }

    draw(down, downColor, 1);
    draw(up, upColor, -1);
    final tp = TextPainter(
      text: TextSpan(
        text: rateText(peak),
        style: TextStyle(color: grid, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(2, 0));
  }

  @override
  bool shouldRepaint(_RatePainter old) => true;
}

/// Vertical bars with two stacked parts, one per day or month.
class StackedBars extends StatelessWidget {
  final List<({String label, double a, double b})> bars;
  final Color aColor, bColor;
  final double height;
  const StackedBars({
    super.key,
    required this.bars,
    required this.aColor,
    required this.bColor,
    this.height = 120,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peak = bars.fold<double>(0, (m, e) => max(m, e.a + e.b));
    return SizedBox(
      height: height + 18,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final (i, bar) in bars.indexed)
            Expanded(
              child: Tooltip(
                message: bar.label,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      height: peak <= 0 ? 2 : max(2, height * (bar.a + bar.b) / peak),
                      child: Column(
                        children: [
                          Expanded(
                            flex: max(1, (bar.b * 1000).round()),
                            child: Container(
                              decoration: BoxDecoration(
                                color: bColor,
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                              ),
                            ),
                          ),
                          if (bar.a > 0)
                            Expanded(
                              flex: max(1, (bar.a * 1000).round()),
                              child: Container(color: aColor),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 14,
                      child: bars.length <= 14 || i % 5 == 0
                          ? FittedBox(
                              child: Text(
                                bar.label,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
