import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:rfw/formats.dart' show parseLibraryFile;
import 'package:rfw/rfw.dart';

/// One surface of a plugin: its RFW widget (from the package's `ui.rfwtxt`)
/// over the data the plugin last sent for it. Events go back to the plugin;
/// nothing here waits on it, so a slow plugin shows stale data, never a
/// stuck frame. See PLUGINS.md.
class PluginView extends StatefulWidget {
  final Plugins plugins;
  final String plugin;
  final String surface;

  /// Where it is shown: `{scope, space?, name?}`, passed to `on-open`.
  final Json context;
  final String Function(String person) nameOf;
  final Widget Function(String person, double size) avatar;
  const PluginView({
    super.key,
    required this.plugins,
    required this.plugin,
    required this.surface,
    required this.context,
    required this.nameOf,
    required this.avatar,
  });

  @override
  State<PluginView> createState() => _PluginViewState();
}

class _PluginViewState extends State<PluginView> {
  static const _core = LibraryName(['core', 'widgets']);
  static const _material = LibraryName(['core', 'material']);
  static const _ournet = LibraryName(['ournet']);

  /// RFW's core widgets, with a ListView that resolves its children as it
  /// builds: RFW's builds them lazily, during layout, where a child reading
  /// data for the first time cannot subscribe to it. Plugin lists are short.
  static final _coreWidgets = LocalWidgetLibrary({
    ...createCoreWidgets().widgets,
    'ListView': (context, source) => ListView(
      scrollDirection:
          ArgumentDecoders.enumValue<Axis>(Axis.values, source, [
            'scrollDirection',
          ]) ??
          Axis.vertical,
      reverse: source.v<bool>(['reverse']) ?? false,
      shrinkWrap: source.v<bool>(['shrinkWrap']) ?? false,
      padding: ArgumentDecoders.edgeInsets(source, ['padding']),
      children: source.childList(['children']),
    ),
  });

  /// Parsed libraries by plugin and source: parsing costs, rendering does not.
  static final _parsed = <String, (int, RemoteWidgetLibrary)>{};

  final runtime = Runtime();
  final content = DynamicContent();
  StreamSubscription<String>? _changes;
  String? _error;
  int _shown = 0;

  LibraryName get _library => LibraryName(['plugin', widget.plugin]);

  @override
  void initState() {
    super.initState();
    runtime
      ..update(_core, _coreWidgets)
      ..update(_material, createMaterialWidgets())
      ..update(
        _ournet,
        ournetWidgets(nameOf: widget.nameOf, avatar: widget.avatar),
      );
    _loadLibrary();
    _changes = widget.plugins.changes.listen((id) {
      if (id != widget.plugin || !mounted) return;
      _loadLibrary();
      _show();
    });
    _show();
    _open();
  }

  @override
  void didUpdateWidget(PluginView old) {
    super.didUpdateWidget(old);
    if (old.plugin != widget.plugin) {
      _loadLibrary();
      _show();
    }
    if (old.plugin != widget.plugin ||
        old.surface != widget.surface ||
        jsonEncode(old.context) != jsonEncode(widget.context)) {
      _open();
    }
  }

  void _open() =>
      widget.plugins.open(widget.plugin, widget.surface, widget.context);

  void _loadLibrary() {
    final source = widget.plugins[widget.plugin]?.ui;
    if (source == null) {
      _error = 'This plugin has nothing to show';
      return;
    }
    final cached = _parsed[widget.plugin];
    try {
      final library = cached != null && cached.$1 == source.hashCode
          ? cached.$2
          : parseLibraryFile(source);
      _parsed[widget.plugin] = (source.hashCode, library);
      runtime.update(_library, library);
      _error = null;
    } catch (e) {
      _error = 'Its interface does not load: $e';
    }
  }

  void _show() {
    final data = widget.plugins.surface(widget.plugin, widget.surface);
    // Data is replaced whole, and only when it is a new value.
    if (identityHashCode(data) == _shown) return;
    _shown = identityHashCode(data);
    content.updateAll(_dynamic(data) as DynamicMap);
    setState(() {});
  }

  /// JSON as RFW data: maps and lists it can read.
  static Object? _dynamic(Object? v) => switch (v) {
    Map() => <String, Object?>{
      for (final MapEntry(:key, :value) in v.entries)
        if (value != null) '$key': _dynamic(value),
    },
    List() => [
      for (final e in v)
        if (e != null) _dynamic(e),
    ],
    _ => v,
  };

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plugin = widget.plugins[widget.plugin];
    final problem = switch (plugin?.status) {
      null => 'This plugin is not installed',
      PluginStatus.failed => plugin!.error ?? 'It stopped',
      PluginStatus.stopped => 'It is switched off',
      _ => _error,
    };
    if (problem != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.extension_off_outlined, size: 48),
              const SizedBox(height: 12),
              Text(problem, textAlign: TextAlign.center),
              if (plugin != null &&
                  plugin.status != PluginStatus.running &&
                  plugin.status != PluginStatus.starting) ...[
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => plugin.enabled
                      ? widget.plugins.restart(plugin.id)
                      : widget.plugins.setEnabled(plugin.id, true),
                  child: Text(plugin.enabled ? 'Restart' : 'Switch on'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return RemoteWidget(
      runtime: runtime,
      data: content,
      widget: FullyQualifiedWidgetName(_library, widget.surface),
      onEvent: (name, args) => widget.plugins.event(
        widget.plugin,
        widget.surface,
        name,
        (jsonDecode(jsonEncode(args)) as Map).cast(),
      ),
    );
  }
}

/// OurNet's widgets for plugin interfaces, as library `ournet`: what core
/// RFW lacks (text input, a canvas, keys) and what makes a plugin look like
/// the rest of the app (people's names and pictures, times, simple markup).
LocalWidgetLibrary ournetWidgets({
  required String Function(String person) nameOf,
  required Widget Function(String person, double size) avatar,
}) => LocalWidgetLibrary(<String, LocalWidgetBuilder>{
  // A text field. `onSubmitted` and `onChanged` send `{value}`.
  'TextInput': (context, source) => _TextInput(
    value: source.v<String>(['value']) ?? '',
    hint: source.v<String>(['hint']),
    label: source.v<String>(['label']),
    lines: source.v<int>(['lines']) ?? 1,
    clearOnSubmit: source.v<bool>(['clearOnSubmit']) ?? false,
    onSubmitted: source.handler<ValueChanged<String>>(
      ['onSubmitted'],
      (trigger) =>
          (value) => trigger({'value': value}),
    ),
    onChanged: source.handler<ValueChanged<String>>(
      ['onChanged'],
      (trigger) =>
          (value) => trigger({'value': value}),
    ),
  ),
  'PersonName': (context, source) => Text(
    nameOf(source.v<String>(['person']) ?? ''),
    style: source.v<bool>(['bold']) == true
        ? const TextStyle(fontWeight: FontWeight.w600)
        : null,
  ),
  'Avatar': (context, source) => avatar(
    source.v<String>(['person']) ?? '',
    _number(source, ['size']) ?? 36,
  ),
  // `at` in milliseconds since the epoch, as "5 min ago".
  'TimeAgo': (context, source) => Text(
    _ago(source.v<int>(['at']) ?? 0),
    style: Theme.of(context).textTheme.bodySmall,
  ),
  // Markdown-like text: headings, bullets, **bold**, *italic*, and
  // [[links]] that send `onLink` with `{target}`.
  'Markup': (context, source) => _Markup(
    text: source.v<String>(['text']) ?? '',
    onLink: source.handler<ValueChanged<String>>(
      ['onLink'],
      (trigger) =>
          (target) => trigger({'target': target}),
    ),
  ),
  // Draws `commands` in a `width` x `height` space scaled to fit. Taps and
  // drags send `{x, y}` in that space.
  'Canvas': (context, source) {
    final commands = <Map<String, Object?>>[];
    for (var i = 0; i < source.length(['commands']); i++) {
      commands.add({
        for (final key in const [
          'op',
          'x',
          'y',
          'w',
          'h',
          'r',
          'x2',
          'y2',
          'color',
          'width',
          'text',
          'size',
          'fill',
        ])
          key: _primitive(source, ['commands', i, key]),
      });
    }
    return _Canvas(
      width: _number(source, ['width']) ?? 100,
      height: _number(source, ['height']) ?? 100,
      background: source.v<int>(['background']),
      commands: commands,
      label: source.v<String>(['label']),
      onActivate: source.handler<VoidCallback>(
        ['onActivate'],
        (trigger) =>
            () => trigger({}),
      ),
      onViewport: source.handler<void Function(Size)>(
        ['onViewport'],
        (trigger) =>
            (size) => trigger({'width': size.width, 'height': size.height}),
      ),
      onTap: source.handler<ValueChanged<Offset>>(
        ['onTap'],
        (trigger) =>
            (p) => trigger({'x': p.dx, 'y': p.dy}),
      ),
      onDrag: source.handler<ValueChanged<Offset>>(
        ['onDrag'],
        (trigger) =>
            (p) => trigger({'x': p.dx, 'y': p.dy}),
      ),
      onPointer: source.handler<void Function(String, int, Offset)>(
        ['onPointer'],
        (trigger) =>
            (phase, pointer, p) => trigger({
              'phase': phase,
              'pointer': pointer,
              'x': p.dx,
              'y': p.dy,
            }),
      ),
    );
  },
  // Sends `onKey` with `{key, down}` for keys pressed while it has focus.
  'Keys': (context, source) => _Keys(
    onKey: source.handler<void Function(String, bool)>(
      ['onKey'],
      (trigger) =>
          (key, down) => trigger({'key': key, 'down': down}),
    ),
    child: source.child(['child']),
  ),
});

/// A number argument, whole or not: JSON from a plugin may give either.
double? _number(DataSource source, List<Object> key) =>
    source.v<double>(key) ?? source.v<int>(key)?.toDouble();

/// Any primitive argument: RFW reads one type at a time.
Object? _primitive(DataSource source, List<Object> key) =>
    source.v<int>(key) ??
    source.v<double>(key) ??
    source.v<String>(key) ??
    source.v<bool>(key);

String _ago(int at) {
  if (at <= 0) return '';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(at));
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 30) return '${d.inDays} d ago';
  final t = DateTime.fromMillisecondsSinceEpoch(at);
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

class _TextInput extends StatefulWidget {
  final String value;
  final String? hint, label;
  final int lines;
  final bool clearOnSubmit;
  final ValueChanged<String>? onSubmitted, onChanged;
  const _TextInput({
    required this.value,
    required this.hint,
    required this.label,
    required this.lines,
    required this.clearOnSubmit,
    required this.onSubmitted,
    required this.onChanged,
  });
  @override
  State<_TextInput> createState() => _TextInputState();
}

class _TextInputState extends State<_TextInput> {
  late final controller = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_TextInput old) {
    super.didUpdateWidget(old);
    // The plugin set a new value (opened another page): show it. Typing
    // does not change `value`, so it is never overwritten.
    if (old.value != widget.value && controller.text != widget.value) {
      controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _submit() {
    widget.onSubmitted?.call(controller.text);
    if (widget.clearOnSubmit) controller.clear();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    minLines: widget.lines > 1 ? widget.lines : null,
    maxLines: widget.lines > 1 ? null : 1,
    keyboardType: widget.lines > 1 ? TextInputType.multiline : null,
    decoration: InputDecoration(
      hintText: widget.hint,
      labelText: widget.label,
      suffixIcon: widget.onSubmitted == null || widget.lines > 1
          ? null
          : IconButton(icon: const Icon(Icons.send), onPressed: _submit),
    ),
    onChanged: widget.onChanged,
    onSubmitted: widget.lines > 1 ? null : (_) => _submit(),
  );
}

class _Markup extends StatelessWidget {
  final String text;
  final ValueChanged<String>? onLink;
  const _Markup({required this.text, required this.onLink});

  static final _inline = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*|\[\[(.+?)\]\]');

  List<InlineSpan> _spans(BuildContext context, String line) {
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in _inline.allMatches(line)) {
      if (m.start > at) spans.add(TextSpan(text: line.substring(at, m.start)));
      if (m[1] != null) {
        spans.add(
          TextSpan(
            text: m[1],
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        );
      } else if (m[2] != null) {
        spans.add(
          TextSpan(
            text: m[2],
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      } else {
        final target = m[3]!;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: InkWell(
              onTap: onLink == null ? null : () => onLink!(target),
              child: Text(
                target,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
        );
      }
      at = m.end;
    }
    if (at < line.length) spans.add(TextSpan(text: line.substring(at)));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final blocks = <Widget>[];
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trimRight();
      if (trimmed.isEmpty) {
        blocks.add(const SizedBox(height: 8));
        continue;
      }
      final heading = RegExp(r'^(#{1,3}) (.*)$').firstMatch(trimmed);
      final bullet = RegExp(r'^[-*] (.*)$').firstMatch(trimmed);
      final style = switch (heading?[1]?.length) {
        1 => theme.headlineSmall,
        2 => theme.titleLarge,
        3 => theme.titleMedium,
        _ => theme.bodyMedium,
      };
      final body = heading?[2] ?? bullet?[1] ?? trimmed;
      final rich = Text.rich(
        TextSpan(style: style, children: _spans(context, body)),
      );
      blocks.add(
        bullet == null
            ? Padding(
                padding: EdgeInsets.only(top: heading == null ? 0 : 8),
                child: rich,
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('  •  '),
                  Expanded(child: rich),
                ],
              ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: blocks,
    );
  }
}

class _Canvas extends StatefulWidget {
  final double width, height;
  final int? background;
  final List<Map<String, Object?>> commands;
  final ValueChanged<Offset>? onTap, onDrag;
  final void Function(String phase, int pointer, Offset position)? onPointer;
  final String? label;
  final VoidCallback? onActivate;
  final void Function(Size)? onViewport;
  const _Canvas({
    required this.width,
    required this.height,
    required this.background,
    required this.commands,
    required this.onTap,
    required this.onDrag,
    this.onPointer,
    this.label,
    this.onActivate,
    this.onViewport,
  });

  @override
  State<_Canvas> createState() => _CanvasState();
}

class _CanvasState extends State<_Canvas> {
  Size? _reportedViewport;
  final _pendingMoves = <int, Offset>{};
  bool _moveScheduled = false;

  // Bound and coalesce high-rate touch input; release discards queued moves.
  void _move(int pointer, Offset position) {
    if (_pendingMoves.length >= 8 && !_pendingMoves.containsKey(pointer)) {
      return;
    }
    _pendingMoves[pointer] = position;
    if (_moveScheduled) return;
    _moveScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _moveScheduled = false;
      final moves = Map<int, Offset>.of(_pendingMoves);
      _pendingMoves.clear();
      if (!mounted) return;
      for (final entry in moves.entries) {
        widget.onPointer?.call('move', entry.key, entry.value);
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _end(String phase, int pointer, Offset position) {
    _pendingMoves.remove(pointer);
    widget.onPointer?.call(phase, pointer, position);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onViewport != null) {
      final viewport = MediaQuery.sizeOf(context);
      if (viewport != _reportedViewport) {
        _reportedViewport = viewport;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onViewport?.call(viewport);
        });
      }
    }
    return _buildCanvas(context);
  }

  Widget _buildCanvas(BuildContext context) => AspectRatio(
    aspectRatio: widget.width / widget.height,
    child: LayoutBuilder(
      builder: (context, box) {
        final scale = box.maxWidth / widget.width;
        Offset local(Offset p) => p / scale;
        return Semantics(
          container: widget.label != null,
          label: widget.label,
          button: widget.onActivate != null,
          onTap: widget.onActivate,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: widget.onPointer == null
                ? null
                : (e) => widget.onPointer!(
                    'down',
                    e.pointer,
                    local(e.localPosition),
                  ),
            onPointerMove: widget.onPointer == null
                ? null
                : (e) => _move(e.pointer, local(e.localPosition)),
            onPointerUp: widget.onPointer == null
                ? null
                : (e) => _end('up', e.pointer, local(e.localPosition)),
            onPointerCancel: widget.onPointer == null
                ? null
                : (e) => _end('cancel', e.pointer, local(e.localPosition)),
            child: GestureDetector(
              onTapDown: widget.onTap == null
                  ? null
                  : (d) => widget.onTap!(local(d.localPosition)),
              onPanUpdate: widget.onDrag == null
                  ? null
                  : (d) => widget.onDrag!(local(d.localPosition)),
              child: RepaintBoundary(
                child: CustomPaint(
                  size: Size(
                    box.maxWidth,
                    box.maxWidth * widget.height / widget.width,
                  ),
                  painter: _Painter(
                    widget.commands,
                    scale,
                    widget.background == null
                        ? null
                        : Color(widget.background!),
                    Theme.of(context).textTheme.bodyMedium?.fontFamily,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _Painter extends CustomPainter {
  final List<Map<String, Object?>> commands;
  final double scale;
  final Color? background;
  final String? fontFamily;
  _Painter(this.commands, this.scale, this.background, this.fontFamily);

  double _d(Object? v) => (v as num?)?.toDouble() ?? 0;

  @override
  void paint(Canvas canvas, Size size) {
    if (background != null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = background!);
    }
    canvas.scale(scale);
    for (final c in commands) {
      final paint = Paint()
        ..color = Color((c['color'] as int?) ?? 0xff000000)
        ..strokeWidth = c['width'] == null ? 1 : _d(c['width'])
        ..style = c['fill'] == false
            ? PaintingStyle.stroke
            : PaintingStyle.fill;
      switch (c['op']) {
        case 'rect':
          canvas.drawRect(
            Rect.fromLTWH(_d(c['x']), _d(c['y']), _d(c['w']), _d(c['h'])),
            paint,
          );
        case 'circle':
          canvas.drawCircle(Offset(_d(c['x']), _d(c['y'])), _d(c['r']), paint);
        case 'line':
          canvas.drawLine(
            Offset(_d(c['x']), _d(c['y'])),
            Offset(_d(c['x2']), _d(c['y2'])),
            paint..style = PaintingStyle.stroke,
          );
        case 'text':
          final text = TextPainter(
            text: TextSpan(
              text: '${c['text'] ?? ''}',
              style: TextStyle(
                color: paint.color,
                fontSize: c['size'] == null ? 14 : _d(c['size']),
                fontFamily: fontFamily,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          text.paint(
            canvas,
            Offset(_d(c['x']) - text.width / 2, _d(c['y']) - text.height / 2),
          );
      }
    }
  }

  @override
  bool shouldRepaint(_Painter old) =>
      old.commands != commands ||
      old.fontFamily != fontFamily ||
      old.scale != scale ||
      old.background != background;
}

class _Keys extends StatefulWidget {
  final void Function(String key, bool down)? onKey;
  final Widget child;
  const _Keys({required this.onKey, required this.child});
  @override
  State<_Keys> createState() => _KeysState();
}

class _KeysState extends State<_Keys> {
  final focus = FocusNode();

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focus,
    autofocus: true,
    onKeyEvent: (_, event) {
      if (widget.onKey == null || event is KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      widget.onKey!(event.logicalKey.keyLabel, event is KeyDownEvent);
      return KeyEventResult.handled;
    },
    child: GestureDetector(
      onTap: focus.requestFocus,
      behavior: HitTestBehavior.translucent,
      child: widget.child,
    ),
  );
}
