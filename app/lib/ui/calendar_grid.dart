import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

import '../controllers/calendar_controller.dart';
import 'calendar_dates.dart';

/// A bar for one occurrence across days, as in the all-day row of the week
/// view and the weeks of the month view.
class EventBarTile extends StatelessWidget {
  final CalendarController controller;
  final Occurrence occurrence;
  final bool continuesBefore, continuesAfter;
  final VoidCallback onTap;
  final double height;
  final bool showTime;
  const EventBarTile({
    super.key,
    required this.controller,
    required this.occurrence,
    required this.onTap,
    this.continuesBefore = false,
    this.continuesAfter = false,
    this.height = 20,
    this.showTime = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = controller.colorOf(occurrence.event);
    final text = onColor(color);
    return Semantics(
      button: true,
      label: '${eventTitle(occurrence.event)}, ${describeWhen(context, occurrence)}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: height,
          margin: EdgeInsets.fromLTRB(continuesBefore ? 0 : 2, 1, continuesAfter ? 0 : 2, 1),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(continuesBefore ? 0 : 4),
              right: Radius.circular(continuesAfter ? 0 : 4),
            ),
          ),
          child: Text(
            showTime && !occurrence.allDay
                ? '${formatClock(context, occurrence.start)} ${eventTitle(occurrence.event)}'
                : eventTitle(occurrence.event),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: text, fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ),
      ),
    );
  }
}

enum _Drag { create, move, resize }

class _DragState {
  final _Drag mode;
  final Occurrence? occurrence;

  /// Minutes between the event's start and where it was grabbed.
  final int grab;
  int day, start, end;
  _DragState(this.mode, this.occurrence, this.day, this.start, this.end, [this.grab = 0]);
}

/// The day, three-day and week views: a column of hours per day with the
/// events laid out in them, an all-day strip above, and a line for now.
///
/// People create events by tapping or dragging on empty time, and move or
/// resize them by dragging (with a mouse) or long-pressing (by touch).
class TimeGrid extends StatefulWidget {
  final CalendarController controller;
  final List<DateTime> days;
  final void Function(Occurrence) onOpen;
  final void Function(DateTime start, DateTime end) onCreate;
  final void Function(DateTime day) onOpenDay;
  final void Function(DateTime day) onCreateAllDay;
  final Future<void> Function(Occurrence, DateTime start, DateTime end) onReschedule;
  const TimeGrid({
    super.key,
    required this.controller,
    required this.days,
    required this.onOpen,
    required this.onCreate,
    required this.onOpenDay,
    required this.onCreateAllDay,
    required this.onReschedule,
  });

  static const hourHeight = 52.0;
  static const gutter = 52.0;

  @override
  State<TimeGrid> createState() => _TimeGridState();
}

class _TimeGridState extends State<TimeGrid> {
  final scroll = ScrollController();
  final bodyKey = GlobalKey();
  Timer? clock;
  DateTime now = DateTime.now();
  bool expandedAllDay = false;
  _DragState? drag;
  bool scrolled = false;

  CalendarController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => now = DateTime.now());
    });
  }

  @override
  void dispose() {
    clock?.cancel();
    scroll.dispose();
    super.dispose();
  }

  void _initialScroll() {
    if (scrolled || !scroll.hasClients) return;
    scrolled = true;
    final today = widget.days.any((d) => sameDay(d, now));
    final hour = today ? math.max(0, now.hour - 2) : 7;
    scroll.jumpTo(
      math.min(hour * TimeGrid.hourHeight, scroll.position.maxScrollExtent),
    );
  }

  int _snap(double minutes) =>
      ((minutes / 15).round() * 15).clamp(0, 24 * 60).toInt();

  /// The day column and minute under a global position, or null outside.
  (int, double)? _locate(Offset global) {
    final box = bodyKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(global);
    final width = box.size.width - TimeGrid.gutter;
    if (width <= 0) return null;
    final day = ((local.dx - TimeGrid.gutter) / (width / widget.days.length))
        .floor()
        .clamp(0, widget.days.length - 1);
    return (day, local.dy / TimeGrid.hourHeight * 60);
  }

  void _begin(_DragState state) => setState(() => drag = state);

  void _update(Offset global) {
    final state = drag;
    final at = _locate(global);
    if (state == null || at == null) return;
    final (day, minute) = at;
    setState(() {
      switch (state.mode) {
        case _Drag.create:
          final anchor = state.grab;
          final m = _snap(minute);
          state.day = day;
          state.start = math.min(anchor, m);
          state.end = math.max(math.max(anchor, m), state.start + 15);
        case _Drag.move:
          final length = state.end - state.start;
          final start = _snap(
            minute - state.grab,
          ).clamp(0, math.max(0, 24 * 60 - length)).toInt();
          state.day = day;
          state.start = start;
          state.end = start + length;
        case _Drag.resize:
          state.end = math.max(_snap(minute), state.start + 15);
      }
    });
  }

  Future<void> _finish() async {
    final state = drag;
    setState(() => drag = null);
    if (state == null) return;
    final day = widget.days[state.day];
    DateTime at(int minutes) => DateTime(day.year, day.month, day.day, 0, minutes);
    switch (state.mode) {
      case _Drag.create:
        widget.onCreate(at(state.start), at(state.end));
      case _Drag.move:
      case _Drag.resize:
        final o = state.occurrence!;
        final start = at(state.start);
        final end = state.mode == _Drag.resize
            ? at(state.end)
            : start.add(o.end.difference(o.start));
        final moved = state.mode == _Drag.resize
            ? !end.isAtSameMomentAs(o.end)
            : !start.isAtSameMomentAs(o.start);
        if (moved) {
          await widget.onReschedule(o, state.mode == _Drag.resize ? o.start : start, end);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final days = widget.days;
    final from = days.first;
    final to = addDays(days.last, 1);
    final all = c.occurrences(from, to);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        _header(context, days),
        _allDay(context, all, days),
        const Divider(height: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              WidgetsBinding.instance.addPostFrameCallback((_) => _initialScroll());
              final columnWidth =
                  (constraints.maxWidth - TimeGrid.gutter) / days.length;
              return SingleChildScrollView(
                controller: scroll,
                child: SizedBox(
                  key: bodyKey,
                  height: 24 * TimeGrid.hourHeight,
                  child: Stack(
                    children: [
                      for (var h = 0; h < 24; h++)
                        Positioned(
                          top: h * TimeGrid.hourHeight,
                          left: 0,
                          right: 0,
                          child: Row(
                            children: [
                              SizedBox(
                                width: TimeGrid.gutter,
                                height: 1,
                                child: h == 0
                                    ? null
                                    : OverflowBox(
                                        maxHeight: 20,
                                        alignment: Alignment.topRight,
                                        child: Padding(
                                          padding: const EdgeInsets.only(right: 6, top: 0),
                                          child: Transform.translate(
                                            offset: const Offset(0, -9),
                                            child: Text(
                                              formatHour(context, h),
                                              textAlign: TextAlign.right,
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                              ),
                              Expanded(child: Divider(height: 1, color: scheme.outlineVariant)),
                            ],
                          ),
                        ),
                      for (var i = 0; i < days.length; i++)
                        Positioned(
                          left: TimeGrid.gutter + i * columnWidth,
                          width: columnWidth,
                          top: 0,
                          bottom: 0,
                          child: _column(context, i, days[i], all, columnWidth),
                        ),
                      if (drag != null) _ghost(context, columnWidth),
                      for (var i = 0; i < days.length; i++)
                        if (sameDay(days[i], now))
                          Positioned(
                            left: TimeGrid.gutter + i * columnWidth - 5,
                            width: columnWidth + 5,
                            top: (now.hour * 60 + now.minute) / 60 * TimeGrid.hourHeight - 5,
                            child: IgnorePointer(
                              child: Row(
                                children: [
                                  Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      color: scheme.error,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  Expanded(child: Container(height: 2, color: scheme.error)),
                                ],
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, List<DateTime> days) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: TimeGrid.gutter,
          child: c.weekNumbers
              ? Center(
                  child: Text(
                    'W${weekNumber(days.first)}',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                )
              : null,
        ),
        for (final day in days)
          Expanded(
            child: InkWell(
              onTap: () => widget.onOpenDay(day),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  children: [
                    Text(
                      weekdayShort(day.weekday).toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 0.5,
                        fontWeight: FontWeight.w600,
                        color: sameDay(day, now) ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: sameDay(day, now) ? scheme.primary : null,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${day.day}',
                        style: TextStyle(
                          fontSize: 18,
                          color: sameDay(day, now) ? scheme.onPrimary : scheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _allDay(BuildContext context, List<Occurrence> all, List<DateTime> days) {
    final bars = layoutBars(all, days);
    final lanes = bars.isEmpty ? 0 : bars.map((b) => b.lane).reduce(math.max) + 1;
    const limit = 3;
    final shownLanes = expandedAllDay ? lanes : math.min(lanes, limit);
    final hidden = [
      for (var d = 0; d < days.length; d++)
        bars.where((b) => b.lane >= shownLanes && b.firstColumn <= d && b.lastColumn >= d).length,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - TimeGrid.gutter) / days.length;
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: SizedBox(
            // Always there, as in other calendars, so a click on it makes an
            // all-day event for that day.
            height: math.max(1, shownLanes) * 22.0 + (lanes > limit ? 18 : 0),
            child: Stack(
              children: [
                Positioned(
                  left: TimeGrid.gutter,
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: Row(
                    children: [
                      for (final day in days)
                        Expanded(
                          child: Tooltip(
                            message: 'Add an all-day event',
                            waitDuration: const Duration(milliseconds: 800),
                            child: InkWell(
                              onTap: () => widget.onCreateAllDay(day),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Positioned(
                  left: 0,
                  width: TimeGrid.gutter,
                  top: 0,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6, top: 4),
                    child: Text(
                      'all-day',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                for (final bar in bars)
                  if (bar.lane < shownLanes)
                    Positioned(
                      left: TimeGrid.gutter + bar.firstColumn * width,
                      width: (bar.lastColumn - bar.firstColumn + 1) * width,
                      top: bar.lane * 22.0,
                      child: EventBarTile(
                        controller: c,
                        occurrence: bar.occurrence,
                        continuesBefore: bar.continuesBefore,
                        continuesAfter: bar.continuesAfter,
                        height: 20,
                        onTap: () => widget.onOpen(bar.occurrence),
                      ),
                    ),
                if (lanes > limit)
                  Positioned(
                    left: TimeGrid.gutter,
                    right: 0,
                    top: shownLanes * 22.0,
                    child: GestureDetector(
                      onTap: () => setState(() => expandedAllDay = !expandedAllDay),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          expandedAllDay
                              ? 'Show less'
                              : [
                                  for (final h in hidden) h,
                                ].reduce(math.max) > 0
                              ? 'Show ${bars.where((b) => b.lane >= shownLanes).length} more'
                              : '',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _column(
    BuildContext context,
    int index,
    DateTime day,
    List<Occurrence> all,
    double width,
  ) {
    final placed = layoutDay(all, day);
    final scheme = Theme.of(context).colorScheme;
    final mouse = {PointerDeviceKind.mouse, PointerDeviceKind.trackpad, PointerDeviceKind.stylus};
    final touch = {PointerDeviceKind.touch};
    return Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: scheme.outlineVariant)),
        color: sameDay(day, now) ? scheme.primary.withValues(alpha: 0.03) : null,
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                final minute = _snap(d.localPosition.dy / TimeGrid.hourHeight * 60 - 15);
                final start = DateTime(day.year, day.month, day.day, 0, math.min(minute, 23 * 60 + 30));
                widget.onCreate(start, start.add(Duration(minutes: c.defaultMinutes)));
              },
              supportedDevices: {...mouse, ...touch},
              child: const SizedBox.expand(),
            ),
          ),
          // Dragging empty time creates an event: by mouse at once, by touch
          // after a long press so scrolling still works.
          Positioned.fill(
            child: RawGestureDetector(
              behavior: HitTestBehavior.translucent,
              gestures: {
                VerticalDragGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
                      () => VerticalDragGestureRecognizer(supportedDevices: mouse),
                      (r) => r
                        ..onStart = (d) {
                          final at = _locate(d.globalPosition);
                          if (at == null) return;
                          final m = _snap(at.$2);
                          _begin(_DragState(_Drag.create, null, at.$1, m, m + 15, m));
                        }
                        ..onUpdate = (d) {
                          _update(d.globalPosition);
                        }
                        ..onEnd = (_) {
                          unawaited(_finish());
                        }
                        ..onCancel = () {
                          setState(() => drag = null);
                        },
                    ),
                LongPressGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                      () => LongPressGestureRecognizer(supportedDevices: touch),
                      (r) => r
                        ..onLongPressStart = (d) {
                          final at = _locate(d.globalPosition);
                          if (at == null) return;
                          final m = _snap(at.$2);
                          _begin(_DragState(_Drag.create, null, at.$1, m, m + 30, m));
                        }
                        ..onLongPressMoveUpdate = (d) {
                          _update(d.globalPosition);
                        }
                        ..onLongPressEnd = (_) {
                          unawaited(_finish());
                        }
                        ..onLongPressCancel = () {
                          setState(() => drag = null);
                        },
                    ),
              },
            ),
          ),
          for (final p in placed) _block(context, p, width, index),
        ],
      ),
    );
  }

  Widget _block(BuildContext context, PlacedEvent p, double width, int index) {
    final o = p.occurrence;
    final color = c.colorOf(o.event);
    final textColor = onColor(color);
    final top = p.startMinute / 60 * TimeGrid.hourHeight;
    final height = math.max(16.0, (p.endMinute - p.startMinute) / 60 * TimeGrid.hourHeight - 1);
    final slot = (width - 4) / p.columns;
    final left = 1 + p.column * slot;
    final blockWidth = p.span * slot - 1;
    final dragging = drag?.occurrence?.id == o.id;
    final mouse = {PointerDeviceKind.mouse, PointerDeviceKind.trackpad, PointerDeviceKind.stylus};
    final touch = {PointerDeviceKind.touch};
    return Positioned(
      top: top,
      left: left,
      width: math.max(8, blockWidth),
      height: height,
      child: Opacity(
        opacity: dragging ? 0.35 : 1,
        child: Semantics(
          button: true,
          label: '${eventTitle(o.event)}, ${describeWhen(context, o)}',
          child: Stack(
            children: [
              Positioned.fill(
                child: RawGestureDetector(
                  behavior: HitTestBehavior.opaque,
                  gestures: {
                    TapGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                          () => TapGestureRecognizer(),
                          (r) => r.onTap = () => widget.onOpen(o),
                        ),
                    PanGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
                          () => PanGestureRecognizer(supportedDevices: mouse),
                          (r) => r
                            ..onStart = (d) {
                              final at = _locate(d.globalPosition);
                              if (at == null) return;
                              _begin(
                                _DragState(
                                  _Drag.move,
                                  o,
                                  at.$1,
                                  p.startMinute,
                                  p.endMinute,
                                  (at.$2 - p.startMinute).round(),
                                ),
                              );
                            }
                            ..onUpdate = (d) {
                          _update(d.globalPosition);
                        }
                            ..onEnd = (_) {
                          unawaited(_finish());
                        }
                            ..onCancel = () {
                          setState(() => drag = null);
                        },
                        ),
                    LongPressGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                          () => LongPressGestureRecognizer(supportedDevices: touch),
                          (r) => r
                            ..onLongPressStart = (d) {
                              final at = _locate(d.globalPosition);
                              if (at == null) return;
                              _begin(
                                _DragState(
                                  _Drag.move,
                                  o,
                                  at.$1,
                                  p.startMinute,
                                  p.endMinute,
                                  (at.$2 - p.startMinute).round(),
                                ),
                              );
                            }
                            ..onLongPressMoveUpdate = (d) {
                          _update(d.globalPosition);
                        }
                            ..onLongPressEnd = (_) {
                          unawaited(_finish());
                        }
                            ..onLongPressCancel = () {
                          setState(() => drag = null);
                        },
                        ),
                  },
                  child: _blockBody(context, o, color, textColor, height, p),
                ),
              ),
              if (!p.continuesAfter)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 8,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeUpDown,
                    child: RawGestureDetector(
                      behavior: HitTestBehavior.translucent,
                      gestures: {
                        VerticalDragGestureRecognizer:
                            GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
                              () => VerticalDragGestureRecognizer(supportedDevices: mouse),
                              (r) => r
                                ..onStart = (_) {
                                  _begin(
                                  _DragState(
                                    _Drag.resize,
                                    o,
                                    index,
                                    p.startMinute,
                                    p.endMinute,
                                  ),
                                );
                                }
                                ..onUpdate = (d) {
                          _update(d.globalPosition);
                        }
                                ..onEnd = (_) {
                          unawaited(_finish());
                        }
                                ..onCancel = () {
                          setState(() => drag = null);
                        },
                            ),
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _blockBody(
    BuildContext context,
    Occurrence o,
    Color color,
    Color textColor,
    double height,
    PlacedEvent p,
  ) {
    // What fits: a line is about 15 pixels, inside 4 of padding.
    final lines = ((height - 4) / 15).floor();
    final compact = lines < 2;
    final title = eventTitle(o.event);
    final time = '${formatClock(context, o.start)} – ${formatClock(context, o.end)}';
    return Container(
      padding: const EdgeInsets.fromLTRB(5, 2, 4, 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(p.continuesBefore ? 0 : 5),
          bottom: Radius.circular(p.continuesAfter ? 0 : 5),
        ),
        border: Border.all(color: Theme.of(context).colorScheme.surface, width: 0.5),
      ),
      child: compact
          ? Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: ', ${formatClock(context, o.start)}'),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: textColor, fontSize: 11.5),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: lines >= 4 ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.w600),
                ),
                Text(
                  time,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: textColor.withValues(alpha: 0.9), fontSize: 11),
                ),
                if (o.event.location.isNotEmpty && lines >= 4)
                  Text(
                    o.event.location,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: textColor.withValues(alpha: 0.9), fontSize: 11),
                  ),
              ],
            ),
    );
  }

  /// The block being created or moved, drawn where it would land.
  Widget _ghost(BuildContext context, double columnWidth) {
    final state = drag!;
    final scheme = Theme.of(context).colorScheme;
    final color = state.occurrence == null
        ? scheme.primary
        : c.colorOf(state.occurrence!.event);
    final day = widget.days[state.day];
    DateTime at(int m) => DateTime(day.year, day.month, day.day, 0, m);
    final label = '${formatClock(context, at(state.start))} – ${formatClock(context, at(state.end))}';
    return Positioned(
      left: TimeGrid.gutter + state.day * columnWidth + 1,
      width: columnWidth - 4,
      top: state.start / 60 * TimeGrid.hourHeight,
      height: math.max(14, (state.end - state.start) / 60 * TimeGrid.hourHeight - 1),
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.fromLTRB(5, 2, 4, 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: scheme.surface, width: 1),
            boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
          ),
          child: Text(
            state.occurrence == null
                ? '(No title)\n$label'
                : '${eventTitle(state.occurrence!.event)}\n$label',
            style: TextStyle(color: onColor(color), fontSize: 12, fontWeight: FontWeight.w600),
            overflow: TextOverflow.clip,
          ),
        ),
      ),
    );
  }
}
