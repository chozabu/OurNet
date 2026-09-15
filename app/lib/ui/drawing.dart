import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A finished drawing: a PNG to show everywhere and its editable strokes.
typedef DrawingResult = ({
  Uint8List png,
  Uint8List strokes,
  int width,
  int height,
});

/// Drawings use a fixed logical page so they look the same on every device.
const drawingWidth = 1080.0, drawingHeight = 1440.0;

class Stroke {
  final String tool; // pen, marker, highlighter
  final int color;
  final double width;
  final List<Offset> points;
  Stroke(this.tool, this.color, this.width, this.points);

  Map<String, Object> toJson() => {
    'tool': tool,
    'color': color,
    'width': width,
    // Rounded to a tenth of a unit to keep the stroke file compact.
    'points': [
      for (final p in points) ...[
        (p.dx * 10).round() / 10,
        (p.dy * 10).round() / 10,
      ],
    ],
  };

  static Stroke fromJson(Map<String, dynamic> json) {
    final raw = (json['points'] as List).cast<num>();
    return Stroke(
      json['tool'] as String? ?? 'pen',
      json['color'] as int? ?? 0xff000000,
      (json['width'] as num? ?? 6).toDouble(),
      [
        for (var i = 0; i + 1 < raw.length; i += 2)
          Offset(raw[i].toDouble(), raw[i + 1].toDouble()),
      ],
    );
  }

  Paint get paint => Paint()
    ..color = Color(
      color,
    ).withValues(alpha: tool == 'highlighter' ? .35 : Color(color).a)
    ..strokeWidth = width
    ..strokeCap = tool == 'highlighter' ? StrokeCap.square : StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke
    ..blendMode = tool == 'highlighter'
        ? BlendMode.multiply
        : BlendMode.srcOver;

  void draw(Canvas canvas) {
    if (points.isEmpty) return;
    if (points.length == 1) {
      canvas.drawCircle(
        points.single,
        width / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length - 1; i++) {
      final mid = (points[i] + points[i + 1]) / 2;
      path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(points.last.dx, points.last.dy);
    canvas.drawPath(path, paint);
  }

  bool near(Offset point, double radius) {
    for (var i = 0; i < points.length; i++) {
      if ((points[i] - point).distance <= radius + width / 2) return true;
      if (i > 0) {
        final a = points[i - 1], b = points[i];
        final ab = b - a;
        final length = ab.distanceSquared;
        if (length == 0) continue;
        final t = (((point - a).dx * ab.dx + (point - a).dy * ab.dy) / length)
            .clamp(0.0, 1.0);
        if ((a + ab * t - point).distance <= radius + width / 2) return true;
      }
    }
    return false;
  }
}

Uint8List encodeStrokes(List<Stroke> strokes) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'version': 1,
      'width': drawingWidth,
      'height': drawingHeight,
      'strokes': [for (final s in strokes) s.toJson()],
    }),
  ),
);

List<Stroke> decodeStrokes(List<int> bytes) {
  final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  return [
    for (final s in (json['strokes'] as List? ?? const []))
      Stroke.fromJson((s as Map).cast<String, dynamic>()),
  ];
}

/// Opens the drawing editor, optionally with existing strokes.
Future<DrawingResult?> editDrawing(
  BuildContext context, {
  List<Stroke> strokes = const [],
}) => Navigator.of(context).push<DrawingResult>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => DrawingEditor(initial: strokes),
  ),
);

class DrawingEditor extends StatefulWidget {
  final List<Stroke> initial;
  const DrawingEditor({super.key, this.initial = const []});
  @override
  State<DrawingEditor> createState() => _DrawingEditorState();
}

class _DrawingEditorState extends State<DrawingEditor> {
  late final strokes = [...widget.initial];
  final undone = <List<Stroke>>[];
  final history = <List<Stroke>>[];
  Stroke? current;
  String tool = 'pen';
  int color = 0xff202124;
  double width = 6;
  bool saving = false, discarding = false;

  static const colors = [
    0xff202124,
    0xffe8453c,
    0xfff9ab00,
    0xff34a853,
    0xff4285f4,
    0xff9c27b0,
    0xff795548,
    0xffffffff,
  ];

  void remember() {
    history.add([...strokes]);
    if (history.length > 100) history.removeAt(0);
    undone.clear();
  }

  void undo() {
    if (history.isEmpty) return;
    setState(() {
      undone.add([...strokes]);
      strokes
        ..clear()
        ..addAll(history.removeLast());
    });
  }

  void redo() {
    if (undone.isEmpty) return;
    setState(() {
      history.add([...strokes]);
      strokes
        ..clear()
        ..addAll(undone.removeLast());
    });
  }

  Offset toPage(Offset local, Size size) => Offset(
    local.dx * drawingWidth / size.width,
    local.dy * drawingHeight / size.height,
  );

  void start(Offset point) {
    if (tool == 'eraser') {
      remember();
      erase(point);
      return;
    }
    remember();
    setState(() {
      current = Stroke(
        tool,
        color,
        tool == 'marker'
            ? width * 2.5
            : tool == 'highlighter'
            ? width * 4
            : width,
        [point],
      );
      strokes.add(current!);
    });
  }

  void move(Offset point) {
    if (tool == 'eraser') {
      erase(point);
      return;
    }
    final stroke = current;
    if (stroke == null) return;
    if (stroke.points.isNotEmpty &&
        (stroke.points.last - point).distance < 1.5) {
      return;
    }
    setState(() => stroke.points.add(point));
  }

  void erase(Offset point) {
    final before = strokes.length;
    strokes.removeWhere((s) => s.near(point, 18));
    if (strokes.length != before) setState(() {});
  }

  Future<void> save() async {
    if (saving) return;
    if (strokes.isEmpty && widget.initial.isEmpty) {
      setState(() => discarding = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
      return;
    }
    setState(() => saving = true);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, drawingWidth, drawingHeight),
      Paint()..color = Colors.white,
    );
    for (final s in strokes) {
      s.draw(canvas);
    }
    final image = await recorder.endRecording().toImage(
      drawingWidth.toInt(),
      drawingHeight.toInt(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (!mounted || data == null) return;
    setState(() => discarding = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    Navigator.pop<DrawingResult>(context, (
      png: data.buffer.asUint8List(),
      strokes: encodeStrokes(strokes),
      width: drawingWidth.toInt(),
      height: drawingHeight.toInt(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): undo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): redo,
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): redo,
      },
      child: PopScope(
        canPop: discarding,
        // Leaving saves, like the back arrow.
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) save();
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              leading: IconButton(
                tooltip: 'Save drawing',
                onPressed: save,
                icon: const Icon(Icons.arrow_back),
              ),
              title: const Text('Drawing'),
              actions: [
                IconButton(
                  tooltip: 'Undo',
                  onPressed: history.isEmpty ? null : undo,
                  icon: const Icon(Icons.undo),
                ),
                IconButton(
                  tooltip: 'Redo',
                  onPressed: undone.isEmpty ? null : redo,
                  icon: const Icon(Icons.redo),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: (value) {
                    if (value == 'clear') {
                      remember();
                      setState(strokes.clear);
                    } else if (value == 'discard') {
                      setState(() => discarding = true);
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) Navigator.pop(context);
                      });
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'clear', child: Text('Clear page')),
                    PopupMenuItem(
                      value: 'discard',
                      child: Text('Discard changes'),
                    ),
                  ],
                ),
              ],
            ),
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            body: Column(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: drawingWidth / drawingHeight,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final size = constraints.biggest;
                          return Listener(
                            onPointerDown: (e) {
                              if (e.kind == PointerDeviceKind.mouse &&
                                  e.buttons != kPrimaryMouseButton) {
                                return;
                              }
                              start(toPage(e.localPosition, size));
                            },
                            onPointerMove: (e) =>
                                move(toPage(e.localPosition, size)),
                            onPointerUp: (_) => current = null,
                            onPointerCancel: (_) => current = null,
                            child: Material(
                              elevation: 2,
                              color: Colors.white,
                              child: ClipRect(
                                child: CustomPaint(
                                  size: size,
                                  painter: _DrawingPainter(strokes, size),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final (name, icon, label) in const [
                          ('pen', Icons.edit, 'Pen'),
                          ('marker', Icons.brush, 'Marker'),
                          ('highlighter', Icons.highlight, 'Highlighter'),
                          ('eraser', Icons.auto_fix_normal, 'Eraser'),
                        ])
                          IconButton.filledTonal(
                            tooltip: label,
                            isSelected: tool == name,
                            onPressed: () => setState(() => tool = name),
                            icon: Icon(icon),
                          ),
                        const SizedBox(width: 8),
                        for (final w in const [3.0, 6.0, 12.0])
                          IconButton(
                            tooltip: 'Width ${w.toInt()}',
                            isSelected: width == w,
                            onPressed: () => setState(() => width = w),
                            icon: Container(
                              width: w + 6,
                              height: w + 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: width == w
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.outline,
                              ),
                            ),
                          ),
                        const SizedBox(width: 8),
                        for (final c in colors)
                          Semantics(
                            label: 'Colour',
                            selected: color == c,
                            button: true,
                            child: InkResponse(
                              onTap: () => setState(() {
                                color = c;
                                if (tool == 'eraser') tool = 'pen';
                              }),
                              radius: 18,
                              child: Container(
                                width: 28,
                                height: 28,
                                margin: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color(c),
                                  border: Border.all(
                                    width: color == c ? 3 : 1,
                                    color: color == c
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.outline,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawingPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Size size;
  _DrawingPainter(this.strokes, this.size);
  @override
  void paint(Canvas canvas, Size _) {
    canvas.save();
    canvas.scale(size.width / drawingWidth, size.height / drawingHeight);
    canvas.saveLayer(
      const Rect.fromLTWH(0, 0, drawingWidth, drawingHeight),
      Paint(),
    );
    for (final s in strokes) {
      s.draw(canvas);
    }
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DrawingPainter old) => true;
}
