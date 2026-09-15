import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Light and dark tints for each shared note colour name in `noteColors`.
/// ARGB values are also sent to Android widgets, which always draw light.
const noteTints = <String, (int, int)>{
  'coral': (0xfffaafa8, 0xff77172e),
  'peach': (0xfff39f76, 0xff692b17),
  'sand': (0xfffff8b8, 0xff7c4a03),
  'mint': (0xffe2f6d3, 0xff264d3b),
  'sage': (0xffb4ddd3, 0xff0c625d),
  'fog': (0xffd4e4ed, 0xff256377),
  'storm': (0xffaeccdc, 0xff284255),
  'dusk': (0xffd3bfdb, 0xff472e5b),
  'blossom': (0xfff6e2dd, 0xff6c394f),
  'clay': (0xffe9e3d4, 0xff4b443a),
  'chalk': (0xffefeff1, 0xff232427),
};

const noteColorNames = <String, String>{
  'default': 'Default',
  'coral': 'Coral',
  'peach': 'Peach',
  'sand': 'Sand',
  'mint': 'Mint',
  'sage': 'Sage',
  'fog': 'Fog',
  'storm': 'Storm',
  'dusk': 'Dusk',
  'blossom': 'Blossom',
  'clay': 'Clay',
  'chalk': 'Chalk',
};

/// Shared background patterns, drawn over the note colour.
const noteBackgroundNames = <String, String>{
  'none': 'None',
  'dots': 'Dots',
  'grid': 'Grid',
  'lines': 'Lined paper',
  'waves': 'Waves',
  'confetti': 'Confetti',
  'leaves': 'Leaves',
};

/// The surface for a note, or null to use the theme's default card colour.
Color? noteColor(BuildContext context, String? name) {
  final tint = noteTints[name];
  if (tint == null) return null;
  return Color(
    Theme.of(context).brightness == Brightness.dark ? tint.$2 : tint.$1,
  );
}

/// Paints a subtle pattern named in [noteBackgroundNames] behind [child].
class NoteBackground extends StatelessWidget {
  final String? name;
  final Widget child;
  const NoteBackground({super.key, required this.name, required this.child});
  @override
  Widget build(BuildContext context) {
    if (name == null ||
        name == 'none' ||
        !noteBackgroundNames.containsKey(name)) {
      return child;
    }
    return CustomPaint(
      painter: NotePatternPainter(
        name!,
        Theme.of(context).colorScheme.onSurface.withValues(alpha: .08),
      ),
      child: child,
    );
  }
}

class NotePatternPainter extends CustomPainter {
  final String name;
  final Color color;
  NotePatternPainter(this.name, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    switch (name) {
      case 'dots':
        paint.style = PaintingStyle.fill;
        for (var y = 12.0; y < size.height; y += 18) {
          for (var x = 12.0; x < size.width; x += 18) {
            canvas.drawCircle(Offset(x, y), 1.6, paint);
          }
        }
      case 'grid':
        for (var x = 0.0; x < size.width; x += 22) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
        }
        for (var y = 0.0; y < size.height; y += 22) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
      case 'lines':
        for (var y = 28.0; y < size.height; y += 28) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
      case 'waves':
        for (var y = 20.0; y < size.height + 20; y += 26) {
          final path = Path()..moveTo(0, y);
          for (var x = 0.0; x <= size.width; x += 8) {
            path.lineTo(x, y + math.sin(x / 18) * 5);
          }
          canvas.drawPath(path, paint);
        }
      case 'confetti':
        final random = math.Random(7);
        paint.strokeWidth = 2.4;
        final count = (size.width * size.height / 1400).clamp(8, 600).toInt();
        for (var i = 0; i < count; i++) {
          final start = Offset(
            random.nextDouble() * size.width,
            random.nextDouble() * size.height,
          );
          final angle = random.nextDouble() * math.pi;
          canvas.drawLine(
            start,
            start + Offset(math.cos(angle) * 6, math.sin(angle) * 6),
            paint,
          );
        }
      case 'leaves':
        final random = math.Random(11);
        final count = (size.width * size.height / 5000).clamp(4, 160).toInt();
        for (var i = 0; i < count; i++) {
          canvas.save();
          canvas.translate(
            random.nextDouble() * size.width,
            random.nextDouble() * size.height,
          );
          canvas.rotate(random.nextDouble() * math.pi * 2);
          final leaf = Path()
            ..moveTo(0, -10)
            ..quadraticBezierTo(8, 0, 0, 10)
            ..quadraticBezierTo(-8, 0, 0, -10)
            ..moveTo(0, -10)
            ..lineTo(0, 10);
          canvas.drawPath(leaf, paint);
          canvas.restore();
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(NotePatternPainter old) =>
      old.name != name || old.color != color;
}

Widget _swatch(
  BuildContext context, {
  required String tooltip,
  required bool selected,
  required VoidCallback onTap,
  required Color color,
  Widget? child,
  double size = 44,
}) {
  final colors = Theme.of(context).colorScheme;
  return Tooltip(
    message: tooltip,
    child: Semantics(
      selected: selected,
      button: true,
      label: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: size / 2 + 4,
        child: Container(
          width: size,
          height: size,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(
              width: selected ? 3 : 1,
              color: selected ? colors.primary : colors.outline,
            ),
          ),
          child: child,
        ),
      ),
    ),
  );
}

/// Bottom sheet palette. Returns a colour name, or `background:<name>` when
/// [backgrounds] is shown and a pattern was chosen.
Future<String?> pickNoteColor(
  BuildContext context,
  String? current, {
  String? background,
  bool backgrounds = false,
}) => showModalBottomSheet<String>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Colour', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final entry in noteColorNames.entries)
                _swatch(
                  context,
                  tooltip: entry.value,
                  selected: (current ?? 'default') == entry.key,
                  onTap: () => Navigator.pop(context, entry.key),
                  color:
                      noteColor(context, entry.key) ??
                      Theme.of(context).colorScheme.surface,
                  child: entry.key == 'default'
                      ? const Icon(Icons.format_color_reset, size: 20)
                      : (current ?? 'default') == entry.key
                      ? const Icon(Icons.check, size: 20)
                      : null,
                ),
            ],
          ),
          if (backgrounds) ...[
            const SizedBox(height: 20),
            Text('Background', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final entry in noteBackgroundNames.entries)
                  _swatch(
                    context,
                    tooltip: entry.value,
                    size: 52,
                    selected: (background ?? 'none') == entry.key,
                    onTap: () =>
                        Navigator.pop(context, 'background:${entry.key}'),
                    color:
                        noteColor(context, current) ??
                        Theme.of(context).colorScheme.surface,
                    child: entry.key == 'none'
                        ? const Icon(Icons.hide_image_outlined, size: 20)
                        : NoteBackground(
                            name: entry.key,
                            child: const SizedBox.expand(),
                          ),
                  ),
              ],
            ),
          ],
        ],
      ),
    ),
  ),
);
