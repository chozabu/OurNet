import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

import '../controllers/calendar_controller.dart';
import 'calendar_dates.dart';
import 'calendar_grid.dart';

/// One occurrence as a row in a list: colour bar, title, when and where.
class EventTile extends StatelessWidget {
  final CalendarController controller;
  final Occurrence occurrence;
  final VoidCallback onTap;
  final bool showDate;
  final bool dense;
  const EventTile({
    super.key,
    required this.controller,
    required this.occurrence,
    required this.onTap,
    this.showDate = false,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final e = occurrence.event;
    final color = controller.colorOf(e);
    final scheme = Theme.of(context).colorScheme;
    final when = occurrence.allDay
        ? (showDate ? describeWhen(context, occurrence) : 'All day')
        : showDate
        ? describeWhen(context, occurrence)
        : '${formatClock(context, occurrence.start)} – ${formatClock(context, occurrence.end)}';
    final group = occurrence.calendar != Calendar.personal && controller.group == null
        ? controller.nameOf(occurrence.calendar)
        : null;
    return Semantics(
      button: true,
      label: '${eventTitle(e)}, ${describeWhen(context, occurrence)}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: dense ? 4 : 7, horizontal: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 5,
                height: dense ? 32 : 40,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      eventTitle(e),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      [
                        when,
                        if (e.location.isNotEmpty) e.location,
                        ?group,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (occurrence.repeats)
                Padding(
                  padding: const EdgeInsets.only(left: 6, top: 2),
                  child: Icon(Icons.repeat, size: 15, color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The month view. Wide windows show each day as a cell with its events as
/// bars and lines; narrow ones show dots and list the chosen day below.
class MonthView extends StatefulWidget {
  final CalendarController controller;
  final void Function(Occurrence) onOpen;
  final void Function(DateTime start, DateTime end, bool allDay) onCreate;
  final void Function(DateTime day) onOpenDay;

  /// An event was dragged onto another day.
  final void Function(Occurrence, DateTime day) onMove;
  const MonthView({
    super.key,
    required this.controller,
    required this.onOpen,
    required this.onCreate,
    required this.onOpenDay,
    required this.onMove,
  });

  @override
  State<MonthView> createState() => _MonthViewState();
}

class _MonthViewState extends State<MonthView> {
  CalendarController get c => widget.controller;

  /// The day an event being dragged is over.
  DateTime? hoverDay;

  @override
  Widget build(BuildContext context) {
    final days = monthGridDays(c.focus, c.firstWeekday);
    final weeks = monthWeeks(c.focus, c.firstWeekday);
    final shownDays = days.take(weeks * 7).toList();
    final all = c.occurrences(shownDays.first, addDays(shownDays.last, 1));
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 620;
        return narrow
            ? _compact(context, shownDays, weeks, all)
            : _wide(context, shownDays, weeks, all, constraints.maxHeight);
      },
    );
  }

  Widget _weekdayRow(BuildContext context, List<DateTime> days, {double lead = 0}) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (lead > 0) SizedBox(width: lead),
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                weekdayShort(days[i].weekday).toUpperCase(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _wide(
    BuildContext context,
    List<DateTime> days,
    int weeks,
    List<Occurrence> all,
    double height,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final lead = c.weekNumbers ? 28.0 : 0.0;
    return Column(
      children: [
        _weekdayRow(context, days, lead: lead),
        const Divider(height: 1),
        Expanded(
          child: Column(
            children: [
              for (var w = 0; w < weeks; w++)
                Expanded(
                  child: _week(context, days.sublist(w * 7, w * 7 + 7), all, lead, scheme),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _week(
    BuildContext context,
    List<DateTime> week,
    List<Occurrence> all,
    double lead,
    ColorScheme scheme,
  ) {
    final today = DateTime.now();
    final bars = layoutBars(all, week);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellWidth = (constraints.maxWidth - lead) / 7;
        const lineHeight = 19.0;
        const numberHeight = 26.0;
        final capacity = math.max(0, ((constraints.maxHeight - numberHeight) / lineHeight).floor());
        final barLanes = bars.isEmpty ? 0 : bars.map((b) => b.lane).reduce(math.max) + 1;
        // Bars keep their lanes across the row; timed lines use what is left.
        final barLimit = math.min(barLanes, math.max(0, capacity - 1));
        final lines = capacity - barLimit;
        // One target over the whole row: events are bars and lines sitting
        // above the day cells, so the day is found from where it was dropped.
        BuildContext? rowContext;
        DateTime? dayAt(Offset global) {
          final box = rowContext?.findRenderObject() as RenderBox?;
          if (box == null) return null;
          final x = box.globalToLocal(global).dx - lead;
          if (x < 0) return null;
          return week[(x / cellWidth).floor().clamp(0, 6)];
        }

        return DragTarget<Occurrence>(
          onMove: (d) {
            final day = dayAt(d.offset);
            if (day != hoverDay) setState(() => hoverDay = day);
          },
          onLeave: (_) => setState(() => hoverDay = null),
          onAcceptWithDetails: (d) {
            final day = dayAt(d.offset);
            setState(() => hoverDay = null);
            if (day != null && !sameDay(d.data.start, day)) {
              widget.onMove(d.data, day);
            }
          },
          builder: (context, _, _) {
            rowContext = context;
            return Stack(
          children: [
            Row(
              children: [
                if (lead > 0)
                  SizedBox(
                    width: lead,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '${weekNumber(week.first)}',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                for (final day in week)
                  Expanded(child: _cell(context, day, today, all, lines, barLimit, bars, scheme)),
              ],
            ),
            for (final bar in bars)
              if (bar.lane < barLimit)
                Positioned(
                  left: lead + bar.firstColumn * cellWidth,
                  width: (bar.lastColumn - bar.firstColumn + 1) * cellWidth,
                  top: numberHeight + bar.lane * lineHeight,
                  child: _draggable(
                    context,
                    bar.occurrence,
                    EventBarTile(
                      controller: c,
                      occurrence: bar.occurrence,
                      continuesBefore: bar.continuesBefore,
                      continuesAfter: bar.continuesAfter,
                      height: lineHeight - 2,
                      onTap: () => widget.onOpen(bar.occurrence),
                    ),
                  ),
                ),
          ],
            );
          },
        );
      },
    );
  }

  Widget _cell(
    BuildContext context,
    DateTime day,
    DateTime today,
    List<Occurrence> all,
    int lines,
    int barLimit,
    List<Bar> bars,
    ColorScheme scheme,
  ) {
    final inMonth = day.month == c.focus.month;
    final isToday = sameDay(day, today);
    final next = addDays(day, 1);
    final timed = [
      for (final o in all)
        if (!isBar(o) && !o.start.isBefore(day) && o.start.isBefore(next)) o,
    ];
    final hiddenBars = bars
        .where((b) => b.lane >= barLimit && dateOnly(b.occurrence.start).compareTo(next) < 0 && !dateOnly(b.occurrence.lastMoment).isBefore(day))
        .length;
    final overflow = timed.length > lines || hiddenBars > 0;
    final shownTimed = overflow ? math.max(0, lines - 1) : timed.length;
    final more = timed.length - shownTimed + hiddenBars;
    return InkWell(
      onTap: () {
        final start = DateTime(day.year, day.month, day.day, 9);
        widget.onCreate(start, start.add(Duration(minutes: c.defaultMinutes)), false);
      },
      child: Container(
        decoration: BoxDecoration(
          color: hoverDay != null && sameDay(hoverDay!, day)
              ? scheme.primary.withValues(alpha: 0.12)
              : null,
          border: Border(
            left: BorderSide(color: scheme.outlineVariant, width: 0.5),
            bottom: BorderSide(color: scheme.outlineVariant, width: 0.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 26,
              child: Center(
                child: GestureDetector(
                  onTap: () => widget.onOpenDay(day),
                  child: Container(
                    width: 24,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isToday ? scheme.primary : null,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      day.day == 1 ? '${day.day} ${monthShort(day.month)}' : '${day.day}',
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                        color: isToday
                            ? scheme.onPrimary
                            : inMonth
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: barLimit * 19.0),
            for (final o in timed.take(shownTimed)) _line(context, o, scheme),
            if (more > 0)
              GestureDetector(
                onTap: () => widget.onOpenDay(day),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 2, 4, 0),
                  child: Text(
                    '$more more',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Makes an event draggable onto another day.
  Widget _draggable(BuildContext context, Occurrence o, Widget child) =>
      Draggable<Occurrence>(
        data: o,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: c.colorOf(o.event),
              borderRadius: BorderRadius.circular(6),
              boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
            ),
            child: Text(
              eventTitle(o.event),
              style: TextStyle(color: onColor(c.colorOf(o.event)), fontSize: 12),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: child),
        child: child,
      );

  Widget _line(BuildContext context, Occurrence o, ColorScheme scheme) {
    final color = c.colorOf(o.event);
    return _draggable(context, o, GestureDetector(
      onTap: () => widget.onOpen(o),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 19,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Row(
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${formatClock(context, o.start)} ${eventTitle(o.event)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
  }

  Widget _compact(
    BuildContext context,
    List<DateTime> days,
    int weeks,
    List<Occurrence> all,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final today = DateTime.now();
    final selected = dateOnly(c.focus);
    final byDay = <DateTime, List<Occurrence>>{};
    for (final o in all) {
      for (final d in o.days) {
        (byDay[d] ??= []).add(o);
      }
    }
    final chosen = [...?byDay[selected]]..sort(Calendar.compareOccurrences);
    return Column(
      children: [
        _weekdayRow(context, days),
        for (var w = 0; w < weeks; w++)
          SizedBox(
            height: 46,
            child: Row(
              children: [
                for (final day in days.sublist(w * 7, w * 7 + 7))
                  Expanded(
                    child: InkWell(
                      onTap: () => c.go(day),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: sameDay(day, selected)
                                    ? scheme.primary
                                    : sameDay(day, today)
                                    ? scheme.primaryContainer
                                    : null,
                                shape: BoxShape.circle,
                              ),
                              child: Text(
                                '${day.day}',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: sameDay(day, selected)
                                      ? scheme.onPrimary
                                      : day.month == c.focus.month
                                      ? scheme.onSurface
                                      : scheme.onSurfaceVariant.withValues(alpha: 0.55),
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            SizedBox(
                              height: 6,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (final o in (byDay[day] ?? const <Occurrence>[]).take(3))
                                    Container(
                                      width: 5,
                                      height: 5,
                                      margin: const EdgeInsets.symmetric(horizontal: 1),
                                      decoration: BoxDecoration(
                                        color: c.colorOf(o.event),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  formatDay(selected),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton(
                onPressed: () => widget.onOpenDay(selected),
                child: const Text('Open day'),
              ),
            ],
          ),
        ),
        Expanded(
          child: chosen.isEmpty
              ? Center(
                  child: Text(
                    'Nothing planned',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView(
                  children: [
                    for (final o in chosen)
                      EventTile(controller: c, occurrence: o, onTap: () => widget.onOpen(o)),
                  ],
                ),
        ),
      ],
    );
  }
}

/// All twelve months of a year, with a dot on days that have something.
class YearView extends StatelessWidget {
  final CalendarController controller;
  final void Function(DateTime day) onOpenDay;
  final void Function(DateTime month) onOpenMonth;
  const YearView({
    super.key,
    required this.controller,
    required this.onOpenDay,
    required this.onOpenMonth,
  });

  @override
  Widget build(BuildContext context) {
    final year = controller.focus.year;
    final all = controller.occurrences(DateTime(year), DateTime(year + 1));
    final busy = <DateTime>{};
    for (final o in all) {
      busy.addAll(o.days);
    }
    final scheme = Theme.of(context).colorScheme;
    final today = DateTime.now();
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900 ? 4 : constraints.maxWidth >= 560 ? 3 : 2;
        final width = (constraints.maxWidth - 24) / columns;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            children: [
              for (var m = 1; m <= 12; m++)
                SizedBox(
                  width: width,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: () => onOpenMonth(DateTime(year, m)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(
                              monthNames[m - 1],
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                color: today.year == year && today.month == m ? scheme.primary : null,
                              ),
                            ),
                          ),
                        ),
                        _mini(context, year, m, busy, today, scheme),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _mini(
    BuildContext context,
    int year,
    int month,
    Set<DateTime> busy,
    DateTime today,
    ColorScheme scheme,
  ) {
    final days = monthGridDays(DateTime(year, month), controller.firstWeekday);
    final weeks = monthWeeks(DateTime(year, month), controller.firstWeekday);
    return Column(
      children: [
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Text(
                  weekdayShort(days[i].weekday).substring(0, 1),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
        for (var w = 0; w < weeks; w++)
          Row(
            children: [
              for (final day in days.sublist(w * 7, w * 7 + 7))
                Expanded(
                  child: day.month != month
                      ? const SizedBox(height: 24)
                      : InkWell(
                          onTap: () => onOpenDay(day),
                          customBorder: const CircleBorder(),
                          child: Container(
                            height: 24,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: sameDay(day, today) ? scheme.primary : null,
                              shape: BoxShape.circle,
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Text(
                                  '${day.day}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: sameDay(day, today)
                                        ? scheme.onPrimary
                                        : scheme.onSurface,
                                  ),
                                ),
                                if (busy.contains(day) && !sameDay(day, today))
                                  Positioned(
                                    bottom: 1,
                                    child: Container(
                                      width: 4,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: scheme.primary,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                ),
            ],
          ),
      ],
    );
  }
}

/// The schedule view: days with something on, in order, as a list that loads
/// further ahead as it is scrolled.
class ScheduleView extends StatefulWidget {
  final CalendarController controller;
  final void Function(Occurrence) onOpen;
  const ScheduleView({super.key, required this.controller, required this.onOpen});

  @override
  State<ScheduleView> createState() => _ScheduleViewState();
}

class _ScheduleViewState extends State<ScheduleView> {
  static const chunk = 45;
  int ahead = chunk, behind = 0;
  DateTime? anchor;

  CalendarController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final focus = dateOnly(c.focus);
    if (anchor != focus) {
      anchor = focus;
      ahead = chunk;
      behind = 0;
    }
    final from = addDays(focus, -behind);
    final to = addDays(focus, ahead);
    final all = c.occurrences(from, to);
    final byDay = <DateTime, List<Occurrence>>{};
    for (final o in all) {
      for (final d in o.days) {
        if (d.isBefore(from) || !d.isBefore(to)) continue;
        (byDay[d] ??= []).add(o);
      }
    }
    final scheme = Theme.of(context).colorScheme;
    final days = byDay.keys.toList()..sort();
    final today = dateOnly(DateTime.now());
    return ListView.builder(
      itemCount: days.length + 2,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Align(
            alignment: Alignment.center,
            child: TextButton.icon(
              onPressed: () => setState(() => behind += chunk),
              icon: const Icon(Icons.expand_less),
              label: const Text('Earlier'),
            ),
          );
        }
        if (i == days.length + 1) {
          if (days.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(40),
              child: Center(
                child: Text(
                  'Nothing scheduled in this time',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            );
          }
          return Align(
            child: TextButton.icon(
              onPressed: () => setState(() => ahead += chunk),
              icon: const Icon(Icons.expand_more),
              label: const Text('Later'),
            ),
          );
        }
        final day = days[i - 1];
        final items = byDay[day]!..sort(Calendar.compareOccurrences);
        final isToday = day == today;
        final header = i == 1 || days[i - 2].month != day.month
            ? Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
                child: Text(
                  formatMonth(day),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              )
            : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?header,
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 64,
                    child: Column(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isToday ? scheme.primary : null,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '${day.day}',
                            style: TextStyle(
                              fontSize: 18,
                              color: isToday ? scheme.onPrimary : scheme.onSurface,
                            ),
                          ),
                        ),
                        Text(
                          weekdayShort(day.weekday).toUpperCase(),
                          style: TextStyle(
                            fontSize: 11,
                            color: isToday ? scheme.primary : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        for (final o in items)
                          EventTile(
                            controller: c,
                            occurrence: o,
                            dense: true,
                            onTap: () => widget.onOpen(o),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
          ],
        );
      },
    );
  }
}
