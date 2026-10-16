import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:rfw/rfw.dart';

/// OurNet's richer widgets for plugin interfaces: charts, stat tiles, a
/// sortable table, a touchpad, switches, status pills, icon buttons and
/// responsive layout. Registered with the `ournet` library by
/// `ournetWidgets` (plugin_view.dart); see docs/PLUGINS.md.
///
/// Each reads its data once per build and keeps interaction state (sorting,
/// search, touches) here, so typing and dragging never wait on the plugin.
Map<String, LocalWidgetBuilder> pluginLayoutWidgets() => {
  // `series`: [{values: [num], color, label?, fill?}]. `min` (0) and `max`
  // (from the data) bound the values; `capacity` points span the width,
  // newest at the right. `top`/`bottom` label the corners.
  'LineChart': (context, source) {
    final series = <_Series>[];
    for (var i = 0; i < math.min(source.length(['series']), 16); i++) {
      final n = math.min(source.length(['series', i, 'values']), 600);
      series.add(
        _Series(
          [
            for (var j = 0; j < n; j++)
              _number(source, ['series', i, 'values', j]) ?? double.nan,
          ],
          Color(source.v<int>(['series', i, 'color']) ?? 0xff3f8fd8),
          source.v<bool>(['series', i, 'fill']) ?? true,
        ),
      );
    }
    return _LineChart(
      series: series,
      min: _number(source, ['min']) ?? 0,
      max: _number(source, ['max']),
      capacity: source.v<int>(['capacity']),
      height: _number(source, ['height']) ?? 120,
      top: source.v<String>(['top']),
      bottom: source.v<String>(['bottom']),
      label: source.v<String>(['label']),
    );
  },
  // A figure with a name, a value, a detail line and optionally a
  // sparkline of `values`. `onTap` makes it selectable.
  'StatTile': (context, source) {
    final n = math.min(source.length(['values']), 600);
    return _StatTile(
      label: source.v<String>(['label']) ?? '',
      value: source.v<String>(['value']) ?? '',
      detail: source.v<String>(['detail']),
      icon: source.v<String>(['icon']),
      color: Color(source.v<int>(['color']) ?? 0xff3f8fd8),
      values: [
        for (var j = 0; j < n; j++)
          _number(source, ['values', j]) ?? double.nan,
      ],
      max: _number(source, ['max']),
      capacity: source.v<int>(['capacity']),
      selected: source.v<bool>(['selected']) ?? false,
      onTap: source.voidHandler(['onTap']),
    );
  },
  // Rows sorted and filtered here. `columns`: [{label, numeric?, flex?,
  // heat?}] (`heat`: the key at which a cell is shaded fully). `rows`:
  // [{id, cells: [text], keys: [num or text]}]. `sortColumn`/`ascending`
  // start the order; `search` (a hint) adds a filter box. `onSelect` sends
  // `{id}`, `onSort` `{column, ascending}`.
  'SortTable': (context, source) {
    final columns = <_Column>[];
    for (var i = 0; i < math.min(source.length(['columns']), 12); i++) {
      columns.add(
        _Column(
          source.v<String>(['columns', i, 'label']) ?? '',
          source.v<bool>(['columns', i, 'numeric']) ?? false,
          _number(source, ['columns', i, 'flex']) ?? 1,
          _number(source, ['columns', i, 'heat']),
        ),
      );
    }
    final rows = <_Row>[];
    for (var i = 0; i < math.min(source.length(['rows']), 2000); i++) {
      rows.add(
        _Row(
          _primitive(source, ['rows', i, 'id']),
          [
            for (var c = 0; c < columns.length; c++)
              source.v<String>(['rows', i, 'cells', c]) ?? '',
          ],
          [
            for (var c = 0; c < columns.length; c++)
              _primitive(source, ['rows', i, 'keys', c]),
          ],
        ),
      );
    }
    return _SortTable(
      columns: columns,
      rows: rows,
      sortColumn: source.v<int>(['sortColumn']),
      ascending: source.v<bool>(['ascending']) ?? false,
      search: source.v<String>(['search']),
      selected: _primitive(source, ['selected']),
      height: _number(source, ['height']) ?? 420,
      empty: source.v<String>(['empty']) ?? 'Nothing to show',
      label: source.v<String>(['label']),
      onSelect: source.handler<ValueChanged<Object?>>(
        ['onSelect'],
        (trigger) =>
            (id) => trigger({'id': id}),
      ),
      onSort: source.handler<void Function(int, bool)>(
        ['onSort'],
        (trigger) =>
            (column, ascending) =>
                trigger({'column': column, 'ascending': ascending}),
      ),
    );
  },
  // A large surface for pointer control. One finger (or a mouse drag)
  // moves, a tap clicks, a two-finger tap or long press right-clicks, two
  // fingers (or the strip at the right edge, or a mouse wheel) scroll.
  // Sends `onMove` {dx, dy} (whole pixels, one per frame at most),
  // `onClick` {button: left | right} and `onScroll` {amount} (notches,
  // positive up). `enabled: false` dims it and sends nothing.
  'Touchpad': (context, source) => _Touchpad(
    enabled: source.v<bool>(['enabled']) ?? true,
    hint: source.v<String>(['hint']),
    height: _number(source, ['height']) ?? 260,
    speed: _number(source, ['speed']) ?? 1.6,
    buttons: source.v<bool>(['buttons']) ?? true,
    onMove: source.handler<void Function(int, int)>(
      ['onMove'],
      (trigger) =>
          (dx, dy) => trigger({'dx': dx, 'dy': dy}),
    ),
    onClick: source.handler<ValueChanged<String>>(
      ['onClick'],
      (trigger) =>
          (button) => trigger({'button': button}),
    ),
    onScroll: source.handler<ValueChanged<int>>(
      ['onScroll'],
      (trigger) =>
          (amount) => trigger({'amount': amount}),
    ),
  ),
  // A labelled switch. `onChanged` sends `{value}`.
  'Toggle': (context, source) {
    final onChanged = source.handler<ValueChanged<bool>>(
      ['onChanged'],
      (trigger) =>
          (value) => trigger({'value': value}),
    );
    return SwitchListTile(
      value: source.v<bool>(['value']) ?? false,
      onChanged: (source.v<bool>(['enabled']) ?? true) ? onChanged : null,
      title: Text(source.v<String>(['label']) ?? ''),
      subtitle: switch (source.v<String>(['detail'])) {
        final detail? => Text(detail),
        null => null,
      },
      secondary: switch (source.v<String>(['icon'])) {
        final icon? => Icon(pluginIcon(icon)),
        null => null,
      },
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
    );
  },
  // A small status label. `tone`: ok, warn, danger, active, off or info.
  'Pill': (context, source) => _Pill(
    label: source.v<String>(['label']) ?? '',
    tone: source.v<String>(['tone']) ?? 'info',
    icon: source.v<String>(['icon']),
  ),
  // A button with an icon (by name: see [pluginIcon]) and optional label.
  // `style`: filled, tonal, outlined, text or icon; `danger` colours it.
  'ActionButton': (context, source) => _ActionButton(
    label: source.v<String>(['label']),
    icon: source.v<String>(['icon']),
    style: source.v<String>(['style']) ?? 'tonal',
    danger: source.v<bool>(['danger']) ?? false,
    tooltip: source.v<String>(['tooltip']),
    expand: source.v<bool>(['expand']) ?? false,
    onPressed: (source.v<bool>(['enabled']) ?? true)
        ? source.voidHandler(['onPressed'])
        : null,
  ),
  // An icon by name (see [pluginIcon]).
  'Glyph': (context, source) => Icon(
    pluginIcon(source.v<String>(['name']) ?? ''),
    size: _number(source, ['size']),
    color: switch (source.v<int>(['color'])) {
      final c? => Color(c),
      null => null,
    },
  ),
  // `narrow` below `breakpoint` logical pixels of width (720), else `wide`.
  'Responsive': (context, source) {
    final breakpoint = _number(source, ['breakpoint']) ?? 720;
    // Both are resolved here, while building: RFW cannot subscribe to data
    // from within layout.
    final narrow = source.child(['narrow']);
    final wide = source.child(['wide']);
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth < breakpoint ? narrow : wide,
    );
  },
  // Children in equal columns, as many as fit at `minWidth` (160) each,
  // `spacing` (8) apart.
  'Tiles': (context, source) {
    final children = source.childList(['children']);
    final minWidth = _number(source, ['minWidth']) ?? 160;
    final spacing = _number(source, ['spacing']) ?? 8;
    final most = source.v<int>(['maxColumns']) ?? 6;
    return LayoutBuilder(
      builder: (context, box) {
        final columns = ((box.maxWidth + spacing) / (minWidth + spacing))
            .floor()
            .clamp(1, math.max(1, most));
        final width = (box.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final child in children)
              SizedBox(width: width.floorToDouble(), child: child),
          ],
        );
      },
    );
  },
  // A titled card around `child`, with `actions` beside the title.
  'Panel': (context, source) {
    final theme = Theme.of(context);
    final subtitle = source.v<String>(['subtitle']);
    final icon = source.v<String>(['icon']);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(pluginIcon(icon), size: 20),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        source.v<String>(['title']) ?? '',
                        style: theme.textTheme.titleMedium,
                      ),
                      if (subtitle != null)
                        Text(subtitle, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                ...source.childList(['actions']),
              ],
            ),
            const SizedBox(height: 10),
            source.child(['child']),
          ],
        ),
      ),
    );
  },
  // One choice of `options` [{value, label, icon?}]; `onSelected` sends
  // `{value}`.
  'Segments': (context, source) {
    final options = [
      for (var i = 0; i < math.min(source.length(['options']), 8); i++)
        (
          value: '${_primitive(source, ['options', i, 'value'])}',
          label: source.v<String>(['options', i, 'label']) ?? '',
          icon: source.v<String>(['options', i, 'icon']),
        ),
    ];
    final selected = '${_primitive(source, ['selected'])}';
    final onSelected = source.handler<ValueChanged<String>>(
      ['onSelected'],
      (trigger) =>
          (value) => trigger({'value': value}),
    );
    if (options.isEmpty) return const SizedBox.shrink();
    return SegmentedButton<String>(
      showSelectedIcon: false,
      segments: [
        for (final o in options)
          ButtonSegment(
            value: o.value,
            label: Text(o.label, overflow: TextOverflow.ellipsis),
            icon: o.icon == null ? null : Icon(pluginIcon(o.icon!)),
          ),
      ],
      selected: {
        options.any((o) => o.value == selected) ? selected : options[0].value,
      },
      onSelectionChanged: onSelected == null
          ? null
          : (s) => onSelected(s.first),
    );
  },
  // A menu of `options` [{value, label, detail?, icon?}] behind a button
  // showing `label` (and `detail`). `onSelected` sends `{value}`.
  'Choice': (context, source) {
    final options = [
      for (var i = 0; i < math.min(source.length(['options']), 64); i++)
        (
          value: '${_primitive(source, ['options', i, 'value'])}',
          label: source.v<String>(['options', i, 'label']) ?? '',
          detail: source.v<String>(['options', i, 'detail']),
          icon: source.v<String>(['options', i, 'icon']),
        ),
    ];
    final onSelected = source.handler<ValueChanged<String>>(
      ['onSelected'],
      (trigger) =>
          (value) => trigger({'value': value}),
    );
    final theme = Theme.of(context);
    final detail = source.v<String>(['detail']);
    final label = source.v<String>(['label']) ?? '';
    final icon = source.v<String>(['icon']) ?? 'devices';
    return MenuAnchor(
      menuChildren: [
        for (final o in options)
          MenuItemButton(
            leadingIcon: o.icon == null ? null : Icon(pluginIcon(o.icon!)),
            onPressed: onSelected == null ? null : () => onSelected(o.value),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(o.label),
                if (o.detail != null)
                  Text(o.detail!, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
      ],
      builder: (context, menu, _) => OutlinedButton(
        onPressed: options.isEmpty
            ? null
            : () => menu.isOpen ? menu.close() : menu.open(),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          alignment: Alignment.centerLeft,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(pluginIcon(icon)),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  if (detail != null)
                    Text(
                      detail,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  },
  // Sends `onShown` when it appears or the app comes back to the
  // foreground, and `onHidden` when it goes or the app is in the
  // background: for work that should run only while it is seen.
  'Presence': (context, source) => _Presence(
    onShown: source.voidHandler(['onShown']),
    onHidden: source.voidHandler(['onHidden']),
    child: source.optionalChild(['child']) ?? const SizedBox.shrink(),
  ),
};

/// Icons plugins name. Unknown names draw a dot.
IconData pluginIcon(String name) => switch (name) {
  'cpu' => Icons.developer_board,
  'memory' => Icons.memory,
  'network' => Icons.swap_vert,
  'disk' => Icons.storage,
  'temperature' => Icons.thermostat,
  'process' => Icons.view_list,
  'speed' => Icons.speed,
  'timer' => Icons.timer_outlined,
  'devices' => Icons.devices,
  'computer' => Icons.computer,
  'phone' => Icons.smartphone,
  'this' => Icons.my_location,
  'pause' => Icons.pause,
  'play' => Icons.play_arrow,
  'refresh' => Icons.refresh,
  'stop' => Icons.stop_circle_outlined,
  'end' => Icons.cancel_outlined,
  'search' => Icons.search,
  'visible' => Icons.visibility_outlined,
  'warning' => Icons.warning_amber,
  'ok' => Icons.check_circle_outline,
  'off' => Icons.block,
  'shield' => Icons.shield_outlined,
  'info' => Icons.info_outline,
  'history' => Icons.history,
  'close' => Icons.close,
  'share' => Icons.podcasts,
  'mouse' => Icons.mouse_outlined,
  'touch' => Icons.touch_app_outlined,
  'keyboard' => Icons.keyboard_outlined,
  'clipboard' => Icons.content_paste,
  'copy' => Icons.content_copy,
  'paste' => Icons.content_paste_go,
  'type' => Icons.keyboard_alt_outlined,
  'send' => Icons.send,
  'previous' => Icons.skip_previous,
  'next' => Icons.skip_next,
  'playpause' => Icons.play_circle_outline,
  'volumedown' => Icons.volume_down,
  'volumeup' => Icons.volume_up,
  'mute' => Icons.volume_off,
  'slides' => Icons.slideshow,
  'fullscreen' => Icons.fullscreen,
  'left' => Icons.keyboard_arrow_left,
  'right' => Icons.keyboard_arrow_right,
  'up' => Icons.keyboard_arrow_up,
  'down' => Icons.keyboard_arrow_down,
  'backspace' => Icons.backspace_outlined,
  'enter' => Icons.keyboard_return,
  'tab' => Icons.keyboard_tab,
  'escape' => Icons.logout,
  'space' => Icons.space_bar,
  'delete' => Icons.delete_outline,
  'home' => Icons.first_page,
  'endkey' => Icons.last_page,
  'pageup' => Icons.arrow_upward,
  'pagedown' => Icons.arrow_downward,
  'settings' => Icons.tune,
  _ => Icons.circle,
};

double? _number(DataSource source, List<Object> key) =>
    source.v<double>(key) ?? source.v<int>(key)?.toDouble();

Object? _primitive(DataSource source, List<Object> key) =>
    source.v<int>(key) ??
    source.v<double>(key) ??
    source.v<String>(key) ??
    source.v<bool>(key);

class _Series {
  final List<double> values;
  final Color color;
  final bool fill;
  const _Series(this.values, this.color, this.fill);
}

class _LineChart extends StatelessWidget {
  final List<_Series> series;
  final double min;
  final double? max;
  final int? capacity;
  final double height;
  final String? top, bottom, label;
  const _LineChart({
    required this.series,
    required this.min,
    required this.max,
    required this.capacity,
    required this.height,
    this.top,
    this.bottom,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Semantics(
      label: label,
      child: SizedBox(
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(6),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  child: CustomPaint(
                    painter: _ChartPainter(
                      series,
                      min,
                      max,
                      capacity,
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                if (top != null)
                  Positioned(right: 6, top: 4, child: Text(top!, style: small)),
                if (bottom != null)
                  Positioned(
                    right: 6,
                    bottom: 4,
                    child: Text(bottom!, style: small),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<_Series> series;
  final double min;
  final double? max;
  final int? capacity;
  final Color grid;
  _ChartPainter(this.series, this.min, this.max, this.capacity, this.grid);

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
    var top = max;
    if (top == null) {
      top = min;
      for (final s in series) {
        for (final v in s.values) {
          if (v.isFinite && v > top!) top = v;
        }
      }
      top = top! <= min ? min + 1 : min + (top - min) * 1.1;
    }
    final span = math.max(top - min, 1e-9);
    final slots = math.max(
      capacity ?? 0,
      series.fold(0, (n, s) => math.max(n, s.values.length)),
    );
    if (slots < 2) return;
    final step = size.width / (slots - 1);
    for (final s in series) {
      final offset = slots - s.values.length;
      final path = Path();
      var started = false;
      double? firstX, lastX;
      for (var i = 0; i < s.values.length; i++) {
        final v = s.values[i];
        if (!v.isFinite) continue;
        final x = (offset + i) * step;
        final y =
            size.height - ((v - min) / span).clamp(0.0, 1.0) * size.height;
        if (!started) {
          path.moveTo(x, y);
          firstX = x;
          started = true;
        } else {
          path.lineTo(x, y);
        }
        lastX = x;
      }
      if (!started) continue;
      if (s.fill) {
        final area = Path.from(path)
          ..lineTo(lastX!, size.height)
          ..lineTo(firstX!, size.height)
          ..close();
        canvas.drawPath(area, Paint()..color = s.color.withValues(alpha: 0.18));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = s.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      !identical(old.series, series) ||
      old.min != min ||
      old.max != max ||
      old.capacity != capacity ||
      old.grid != grid;
}

class _StatTile extends StatelessWidget {
  final String label, value;
  final String? detail, icon;
  final Color color;
  final List<double> values;
  final double? max;
  final int? capacity;
  final bool selected;
  final VoidCallback? onTap;
  const _StatTile({
    required this.label,
    required this.value,
    required this.detail,
    required this.icon,
    required this.color,
    required this.values,
    required this.max,
    required this.capacity,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: selected
          ? scheme.secondaryContainer
          : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: selected ? color : Colors.transparent),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(pluginIcon(icon!), size: 18, color: color),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (detail != null)
                Text(
                  detail!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              if (values.isNotEmpty) ...[
                const SizedBox(height: 6),
                SizedBox(
                  height: 32,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _ChartPainter(
                        [_Series(values, color, true)],
                        0,
                        max,
                        capacity,
                        Colors.transparent,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Column {
  final String label;
  final bool numeric;
  final double flex;
  final double? heat;
  const _Column(this.label, this.numeric, this.flex, this.heat);
}

class _Row {
  final Object? id;
  final List<String> cells;
  final List<Object?> keys;
  late final String text = cells.join('\u0000').toLowerCase();
  _Row(this.id, this.cells, this.keys);
}

class _SortTable extends StatefulWidget {
  final List<_Column> columns;
  final List<_Row> rows;
  final int? sortColumn;
  final bool ascending;
  final String? search, label;
  final Object? selected;
  final double height;
  final String empty;
  final ValueChanged<Object?>? onSelect;
  final void Function(int column, bool ascending)? onSort;
  const _SortTable({
    required this.columns,
    required this.rows,
    required this.sortColumn,
    required this.ascending,
    required this.search,
    required this.selected,
    required this.height,
    required this.empty,
    required this.onSelect,
    required this.onSort,
    this.label,
  });

  @override
  State<_SortTable> createState() => _SortTableState();
}

class _SortTableState extends State<_SortTable> {
  late int? column = widget.sortColumn;
  late bool ascending = widget.ascending;
  late Object? selected = widget.selected;
  String query = '';
  final scroll = ScrollController();
  final _searchController = TextEditingController();

  @override
  void didUpdateWidget(_SortTable old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) selected = widget.selected;
    if (old.sortColumn != widget.sortColumn ||
        old.ascending != widget.ascending) {
      column = widget.sortColumn;
      ascending = widget.ascending;
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    _searchController.dispose();
    super.dispose();
  }

  static int _compare(Object? a, Object? b) => switch ((a, b)) {
    (num a, num b) => a.compareTo(b),
    (String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()),
    (null, null) => 0,
    (null, _) => -1,
    (_, null) => 1,
    _ => '$a'.compareTo('$b'),
  };

  void _sort(int c) {
    setState(() {
      if (column == c) {
        ascending = !ascending;
      } else {
        column = c;
        // Text reads A to Z first; figures largest first, like a task
        // manager.
        ascending = !widget.columns[c].numeric;
      }
    });
    widget.onSort?.call(c, ascending);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final q = query.trim().toLowerCase();
    final rows = [
      for (final r in widget.rows)
        if (q.isEmpty || r.text.contains(q)) r,
    ];
    final c = column;
    if (c != null && c < widget.columns.length) {
      rows.sort((a, b) {
        final order = _compare(a.keys[c], b.keys[c]);
        return ascending ? order : -order;
      });
    }
    Widget cell(int i, Widget child, {Color? shade}) => Expanded(
      flex: (widget.columns[i].flex * 10).round().clamp(1, 100),
      child: ColoredBox(
        color: shade ?? Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Align(
            alignment: widget.columns[i].numeric
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: child,
          ),
        ),
      ),
    );
    final header = Row(
      children: [
        for (var i = 0; i < widget.columns.length; i++)
          cell(
            i,
            InkWell(
              onTap: () => _sort(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        widget.columns[i].label,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: column == i ? FontWeight.w700 : null,
                        ),
                      ),
                    ),
                    if (column == i)
                      Icon(
                        ascending ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 14,
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
    return Semantics(
      label: widget.label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.search != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                decoration: InputDecoration(
                  hintText: widget.search,
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                            _searchController.clear();
                            query = '';
                          }),
                        ),
                ),
                controller: _searchController,
                onChanged: (v) => setState(() => query = v),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(6),
              ),
            ),
            child: header,
          ),
          SizedBox(
            height: widget.height,
            child: rows.isEmpty
                ? Center(child: Text(q.isEmpty ? widget.empty : 'No matches'))
                : Scrollbar(
                    controller: scroll,
                    child: ListView.builder(
                      controller: scroll,
                      itemCount: rows.length,
                      itemExtent: 38,
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        final chosen = row.id != null && row.id == selected;
                        return Material(
                          color: chosen
                              ? scheme.secondaryContainer
                              : index.isOdd
                              ? scheme.surfaceContainerHighest.withValues(
                                  alpha: 0.25,
                                )
                              : Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              setState(() => selected = row.id);
                              widget.onSelect?.call(row.id);
                            },
                            child: Row(
                              children: [
                                for (var i = 0; i < widget.columns.length; i++)
                                  cell(
                                    i,
                                    Text(
                                      row.cells[i],
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: i == 0 && chosen
                                          ? theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                )
                                          : theme.textTheme.bodyMedium,
                                    ),
                                    shade: _heat(
                                      widget.columns[i],
                                      row.keys[i],
                                      scheme.primary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              q.isEmpty
                  ? '${widget.rows.length} rows'
                  : '${rows.length} of ${widget.rows.length} rows',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  /// A shade for a cell by how near its key is to the column's `heat`.
  static Color? _heat(_Column column, Object? key, Color color) {
    final heat = column.heat;
    if (heat == null || key is! num || heat <= 0) return null;
    final share = (key / heat).clamp(0.0, 1.0).toDouble();
    if (share < 0.01) return null;
    return color.withValues(alpha: 0.06 + share * 0.34);
  }
}

class _Pill extends StatelessWidget {
  final String label, tone;
  final String? icon;
  const _Pill({required this.label, required this.tone, this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (Color background, Color foreground) = switch (tone) {
      'ok' => (
        dark ? const Color(0xff1f3d2b) : const Color(0xffdcf3e3),
        dark ? const Color(0xff8fe0a8) : const Color(0xff16632f),
      ),
      'warn' => (
        dark ? const Color(0xff45391a) : const Color(0xfffff1cc),
        dark ? const Color(0xffffd36b) : const Color(0xff7a5600),
      ),
      'danger' || 'active' => (scheme.errorContainer, scheme.onErrorContainer),
      'off' => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
      _ => (scheme.secondaryContainer, scheme.onSecondaryContainer),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(pluginIcon(icon!), size: 14, color: foreground),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String? label, icon, tooltip;
  final String style;
  final bool danger, expand;
  final VoidCallback? onPressed;
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.style,
    required this.danger,
    required this.tooltip,
    required this.expand,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glyph = icon == null ? null : Icon(pluginIcon(icon!));
    final text = label == null
        ? null
        : Text(label!, overflow: TextOverflow.ellipsis, maxLines: 1);
    Widget button;
    if (style == 'icon' || text == null) {
      button = IconButton.filledTonal(
        onPressed: onPressed,
        icon: glyph ?? const Icon(Icons.circle),
        tooltip: tooltip ?? label,
        style: danger
            ? IconButton.styleFrom(
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer,
              )
            : null,
      );
    } else {
      final dangerStyle = danger
          ? FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            )
          : null;
      button = switch (style) {
        'filled' =>
          glyph == null
              ? FilledButton(
                  onPressed: onPressed,
                  style: dangerStyle,
                  child: text,
                )
              : FilledButton.icon(
                  onPressed: onPressed,
                  style: dangerStyle,
                  icon: glyph,
                  label: text,
                ),
        'outlined' =>
          glyph == null
              ? OutlinedButton(onPressed: onPressed, child: text)
              : OutlinedButton.icon(
                  onPressed: onPressed,
                  icon: glyph,
                  label: text,
                ),
        'text' =>
          glyph == null
              ? TextButton(onPressed: onPressed, child: text)
              : TextButton.icon(onPressed: onPressed, icon: glyph, label: text),
        _ =>
          glyph == null
              ? FilledButton.tonal(
                  onPressed: onPressed,
                  style: danger
                      ? FilledButton.styleFrom(
                          backgroundColor: scheme.errorContainer,
                          foregroundColor: scheme.onErrorContainer,
                        )
                      : null,
                  child: text,
                )
              : FilledButton.tonalIcon(
                  onPressed: onPressed,
                  style: danger
                      ? FilledButton.styleFrom(
                          backgroundColor: scheme.errorContainer,
                          foregroundColor: scheme.onErrorContainer,
                        )
                      : null,
                  icon: glyph,
                  label: text,
                ),
      };
      if (tooltip != null) button = Tooltip(message: tooltip, child: button);
    }
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// A touchpad: the logic of `Touchpad` (see [pluginLayoutWidgets]).
class _Touchpad extends StatefulWidget {
  final bool enabled, buttons;
  final String? hint;
  final double height, speed;
  final void Function(int dx, int dy)? onMove;
  final ValueChanged<String>? onClick;
  final ValueChanged<int>? onScroll;
  const _Touchpad({
    required this.enabled,
    required this.hint,
    required this.height,
    required this.speed,
    required this.buttons,
    required this.onMove,
    required this.onClick,
    required this.onScroll,
  });

  @override
  State<_Touchpad> createState() => _TouchpadState();
}

class _TouchpadState extends State<_Touchpad> {
  /// Width of the scroll strip at the right edge.
  static const strip = 44.0;

  /// Movement in pixels that still counts as a tap.
  static const slop = 12.0;

  /// Finger travel per scroll notch.
  static const notch = 28.0;

  final _points = <int, Offset>{};
  final _starts = <int, Offset>{};
  int _most = 0;
  DateTime _down = DateTime.now();
  bool _moved = false, _inStrip = false, _longPressed = false;
  double _dx = 0, _dy = 0, _scroll = 0;
  bool _flushScheduled = false;
  Timer? _longPress;
  Offset? _flash;

  @override
  void dispose() {
    _longPress?.cancel();
    super.dispose();
  }

  bool get _live => widget.enabled;

  void _flush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flushScheduled = false;
      if (!mounted || !_live) {
        _dx = _dy = 0;
        return;
      }
      final (x, y) = (_dx.truncate(), _dy.truncate());
      if (x != 0 || y != 0) {
        _dx -= x;
        _dy -= y;
        widget.onMove?.call(x.clamp(-2000, 2000), y.clamp(-2000, 2000));
      }
      final notches = (_scroll / notch).truncate();
      if (notches != 0) {
        _scroll -= notches * notch;
        // Natural scrolling: fingers up move the page up (wheel down).
        widget.onScroll?.call(notches.clamp(-10, 10));
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _click(String button, Offset at) {
    if (!_live) return;
    widget.onClick?.call(button);
    setState(() => _flash = at);
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  void _pointerDown(PointerDownEvent e, double width) {
    if (_points.isEmpty) {
      _most = 0;
      _moved = false;
      _longPressed = false;
      _down = DateTime.now();
      _inStrip = e.localPosition.dx > width - strip;
      _scroll = 0;
      if (e.kind != PointerDeviceKind.mouse) {
        _longPress?.cancel();
        _longPress = Timer(const Duration(milliseconds: 550), () {
          if (_points.length == 1 && !_moved && !_inStrip) {
            _longPressed = true;
            _click('right', _points.values.first);
          }
        });
      }
    }
    _points[e.pointer] = e.localPosition;
    _starts[e.pointer] = e.localPosition;
    _most = math.max(_most, _points.length);
    setState(() {});
  }

  void _pointerMove(PointerMoveEvent e) {
    final before = _points[e.pointer];
    if (before == null) return;
    _points[e.pointer] = e.localPosition;
    final start = _starts[e.pointer]!;
    if ((e.localPosition - start).distance > slop) {
      _moved = true;
      _longPress?.cancel();
    }
    final delta = e.localPosition - before;
    if (_points.length >= 2 || _inStrip) {
      // Two fingers: the first finger's travel scrolls (halved, as both
      // report it).
      if (_points.length < 2 || e.pointer == _points.keys.first) {
        _scroll -= delta.dy;
      }
    } else {
      // Faster strokes travel further, like a laptop touchpad.
      final speed = delta.distance;
      final gain = widget.speed * (1 + math.min(speed / 12, 2.5));
      _dx += delta.dx * gain;
      _dy += delta.dy * gain;
    }
    _flush();
    setState(() {});
  }

  void _pointerUp(PointerEvent e, {bool cancelled = false}) {
    final at = _points.remove(e.pointer);
    _starts.remove(e.pointer);
    if (_points.isEmpty) {
      _longPress?.cancel();
      final quick =
          DateTime.now().difference(_down) < const Duration(milliseconds: 300);
      if (!cancelled && !_moved && !_longPressed && quick && at != null) {
        final secondary =
            e is PointerUpEvent &&
            e.kind == PointerDeviceKind.mouse &&
            _secondary;
        if (_inStrip && _most == 1 && !secondary) {
          // A tap on the strip does nothing: it is for scrolling.
        } else {
          _click(_most >= 2 || secondary ? 'right' : 'left', at);
        }
      }
      _secondary = false;
    }
    setState(() {});
  }

  bool _secondary = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pad = LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            if (e.kind == PointerDeviceKind.mouse &&
                e.buttons & kSecondaryMouseButton != 0) {
              _secondary = true;
            }
            _pointerDown(e, width);
          },
          onPointerMove: _pointerMove,
          onPointerUp: _pointerUp,
          onPointerCancel: (e) => _pointerUp(e, cancelled: true),
          onPointerSignal: (e) {
            if (e is PointerScrollEvent && _live && e.scrollDelta.dy != 0) {
              // A wheel notch is about 100 logical pixels.
              final n = (-e.scrollDelta.dy / 100).round();
              widget.onScroll?.call(
                (n == 0 ? -e.scrollDelta.dy.sign.toInt() : n).clamp(-10, 10),
              );
            }
          },
          // Claim every touch, so the page around does not scroll instead.
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              EagerGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                    EagerGestureRecognizer.new,
                    (_) {},
                  ),
            },
            child: CustomPaint(
              painter: _PadPainter(
                points: _points.values.toList(),
                flash: _flash,
                strip: strip,
                surface: widget.enabled
                    ? scheme.surfaceContainerHighest
                    : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                accent: scheme.primary,
                line: scheme.outlineVariant,
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: strip),
                  child: Text(
                    widget.hint ??
                        'Drag to move · tap to click\nTwo fingers: right-click and scroll',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    return Semantics(
      label: 'Touchpad',
      enabled: widget.enabled,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(16),
              bottom: Radius.circular(widget.buttons ? 0 : 16),
            ),
            child: SizedBox(height: widget.height, child: pad),
          ),
          if (widget.buttons)
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  for (final (button, label) in const [
                    ('left', 'Left click'),
                    ('right', 'Right click'),
                  ])
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          top: 2,
                          right: button == 'left' ? 1 : 0,
                          left: button == 'right' ? 1 : 0,
                        ),
                        child: Material(
                          color: scheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(
                              button == 'left' ? 16 : 0,
                            ),
                            bottomRight: Radius.circular(
                              button == 'right' ? 16 : 0,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: widget.enabled
                                ? () => widget.onClick?.call(button)
                                : null,
                            child: Center(
                              child: Text(
                                label,
                                style: theme.textTheme.labelLarge,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PadPainter extends CustomPainter {
  final List<Offset> points;
  final Offset? flash;
  final double strip;
  final Color surface, accent, line;
  _PadPainter({
    required this.points,
    required this.flash,
    required this.strip,
    required this.surface,
    required this.accent,
    required this.line,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = surface);
    // The scroll strip, with grip marks.
    final x = size.width - strip;
    canvas.drawRect(
      Rect.fromLTWH(x, 0, strip, size.height),
      Paint()..color = line.withValues(alpha: 0.25),
    );
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()..color = line,
    );
    final mid = size.height / 2;
    for (var i = -2; i <= 2; i++) {
      canvas.drawLine(
        Offset(x + strip / 2 - 8, mid + i * 9),
        Offset(x + strip / 2 + 8, mid + i * 9),
        Paint()
          ..color = line
          ..strokeWidth = 2,
      );
    }
    for (final p in points) {
      canvas.drawCircle(p, 22, Paint()..color = accent.withValues(alpha: 0.25));
      canvas.drawCircle(p, 6, Paint()..color = accent);
    }
    if (flash != null) {
      canvas.drawCircle(
        flash!,
        30,
        Paint()
          ..color = accent.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
  }

  @override
  bool shouldRepaint(_PadPainter old) => true;
}

class _Presence extends StatefulWidget {
  final VoidCallback? onShown, onHidden;
  final Widget child;
  const _Presence({
    required this.onShown,
    required this.onHidden,
    required this.child,
  });
  @override
  State<_Presence> createState() => _PresenceState();
}

class _PresenceState extends State<_Presence> with WidgetsBindingObserver {
  bool _shown = false;
  late VoidCallback? _hidden = widget.onHidden;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _show(true);
    });
  }

  @override
  void didUpdateWidget(_Presence old) {
    super.didUpdateWidget(old);
    _hidden = widget.onHidden;
  }

  void _show(bool shown) {
    if (shown == _shown) return;
    _shown = shown;
    (shown ? widget.onShown : _hidden)?.call();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A window that is only unfocused (inactive) is still seen.
    _show(
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _show(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
