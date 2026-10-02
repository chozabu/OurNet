import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';

import '../controllers/calendar_controller.dart';
import 'calendar_dates.dart';
import 'calendar_flows.dart';
import 'calendar_grid.dart';
import 'calendar_month.dart';

/// The calendar screen: a toolbar, the chosen view, and on wide windows a
/// sidebar with a month to jump about in and a switch for each calendar.
/// For a group's own calendar ([CalendarController.group]) it shows that
/// group's events alone.
class CalendarPage extends StatefulWidget {
  final CalendarController controller;
  final CalendarFlows flows;
  const CalendarPage({super.key, required this.controller, required this.flows});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  final focus = FocusNode(debugLabel: 'calendar');
  final searchField = TextEditingController();
  final searchFocus = FocusNode();
  bool searching = false;

  CalendarController get c => widget.controller;
  CalendarFlows get flows => widget.flows;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    focus.dispose();
    searchField.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool get _typing =>
      FocusManager.instance.primaryFocus?.context?.widget is EditableText;

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _typing) return KeyEventResult.ignored;
    final pressed = HardwareKeyboard.instance;
    if (pressed.isControlPressed || pressed.isMetaPressed || pressed.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.character?.toLowerCase();
    switch (key) {
      case 'd' || 'w' || 'm' || 'y' || 'a' || '3':
        c.setView(CalendarView.values.firstWhere((v) => v.key == key));
      case 't':
        c.today();
      case 'j' || 'n':
        c.step(1);
      case 'k' || 'p':
        c.step(-1);
      case 'c':
        unawaited(flows.create(context, calendar: c.group));
      case '/':
        _startSearch();
      default:
        return switch (event.logicalKey) {
          LogicalKeyboardKey.escape when searching => _stopSearch(),
          _ => KeyEventResult.ignored,
        };
    }
    return KeyEventResult.handled;
  }

  void _startSearch() {
    setState(() => searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => searchFocus.requestFocus());
  }

  KeyEventResult _stopSearch() {
    searchField.clear();
    c.search('');
    setState(() => searching = false);
    focus.requestFocus();
    return KeyEventResult.handled;
  }

  String get _title {
    final f = c.focus;
    switch (c.view) {
      case CalendarView.month || CalendarView.schedule:
        return formatMonth(f);
      case CalendarView.year:
        return '${f.year}';
      default:
        final days = c.gridDays;
        final a = days.first, b = days.last;
        if (days.length == 1) {
          return '${weekdayNames[a.weekday - 1]}, ${a.day} ${monthNames[a.month - 1]} ${a.year}';
        }
        if (a.month == b.month) return '${a.day} – ${b.day} ${monthNames[a.month - 1]} ${a.year}';
        if (a.year == b.year) {
          return '${a.day} ${monthShort(a.month)} – ${b.day} ${monthShort(b.month)} ${a.year}';
        }
        return '${a.day} ${monthShort(a.month)} ${a.year} – ${b.day} ${monthShort(b.month)} ${b.year}';
    }
  }

  Future<void> _create() => flows.create(context, calendar: c.group);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900 && c.group == null;
        // Swiping sideways by touch moves a screenful, as other calendars do.
        // Mice keep their own drags: moving and resizing events.
        final body = searching
            ? _results(context)
            : GestureDetector(
                behavior: HitTestBehavior.translucent,
                supportedDevices: const {PointerDeviceKind.touch},
                onHorizontalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v.abs() > 500) c.step(v < 0 ? 1 : -1);
                },
                child: _view(context),
              );
        return Focus(
          focusNode: focus,
          autofocus: true,
          onKeyEvent: _key,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            floatingActionButton: wide
                ? null
                : FloatingActionButton(
                    tooltip: 'New event',
                    onPressed: _create,
                    child: const Icon(Icons.add),
                  ),
            body: Row(
              children: [
                if (wide) SizedBox(width: 248, child: _sidebar(context)),
                if (wide) const VerticalDivider(width: 1),
                Expanded(
                  child: Column(
                    children: [
                      _toolbar(context, constraints.maxWidth, wide),
                      const Divider(height: 1),
                      if (!c.ready)
                        const LinearProgressIndicator(minHeight: 2)
                      else
                        const SizedBox(height: 2),
                      Expanded(child: body),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _toolbar(BuildContext context, double width, bool wide) {
    final compact = width < 640;
    if (searching) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Close search',
              icon: const Icon(Icons.arrow_back),
              onPressed: _stopSearch,
            ),
            Expanded(
              child: TextField(
                controller: searchField,
                focusNode: searchFocus,
                decoration: const InputDecoration(
                  hintText: 'Search events',
                  border: InputBorder.none,
                ),
                onChanged: c.search,
              ),
            ),
            if (searchField.text.isNotEmpty)
              IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close),
                onPressed: () {
                  searchField.clear();
                  c.search('');
                },
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          if (wide)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add),
                label: const Text('Create'),
              ),
            ),
          if (!compact)
            OutlinedButton(onPressed: c.today, child: const Text('Today'))
          else
            IconButton(
              tooltip: 'Today',
              icon: const Icon(Icons.today),
              onPressed: c.today,
            ),
          IconButton(
            tooltip: 'Previous',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => c.step(-1),
          ),
          IconButton(
            tooltip: 'Next',
            icon: const Icon(Icons.chevron_right),
            onPressed: () => c.step(1),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: c.focus,
                  firstDate: DateTime(1970),
                  lastDate: DateTime(2100),
                );
                if (picked != null) c.go(picked);
              },
              child: Text(
                _title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: _startSearch,
          ),
          PopupMenuButton<CalendarView>(
            tooltip: 'View',
            initialValue: c.view,
            onSelected: c.setView,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(c.view.label),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
            itemBuilder: (context) => [
              for (final v in CalendarView.values)
                PopupMenuItem(
                  value: v,
                  child: Row(
                    children: [
                      Expanded(child: Text(v.label)),
                      Text(
                        v.key.toUpperCase(),
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (!wide && c.group == null)
            IconButton(
              tooltip: 'Calendars',
              icon: const Icon(Icons.layers_outlined),
              onPressed: _showCalendars,
            ),
          _settingsMenu(context),
        ],
      ),
    );
  }

  Widget _settingsMenu(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Calendar settings',
    icon: const Icon(Icons.more_vert),
    onSelected: (v) {
      switch (v) {
        case 'import':
          unawaited(flows.importFile(context, c.group ?? Calendar.personal));
        case 'export':
          unawaited(flows.exportFile(c.group ?? Calendar.personal));
        case 'deleted':
          unawaited(flows.showDeleted(context));
        case 'settings':
          unawaited(_settings());
      }
    },
    itemBuilder: (context) => const [
      PopupMenuItem(value: 'settings', child: Text('Settings')),
      PopupMenuItem(value: 'deleted', child: Text('Recently deleted')),
      PopupMenuItem(value: 'import', child: Text('Import .ics file')),
      PopupMenuItem(value: 'export', child: Text('Export as .ics file')),
    ],
  );

  Future<void> _settings() => showDialog<void>(
    context: context,
    builder: (context) => _SettingsDialog(controller: c),
  );

  Widget _view(BuildContext context) {
    return switch (c.view) {
      CalendarView.day || CalendarView.threeDays || CalendarView.week => TimeGrid(
        key: ValueKey('grid/${c.view.name}'),
        controller: c,
        days: c.gridDays,
        onOpen: (o) => flows.open(context, o),
        onCreate: (start, end) => flows.create(context, start: start, end: end, calendar: c.group),
        onOpenDay: (day) {
          c.go(day);
          c.setView(CalendarView.day);
        },
        onCreateAllDay: (day) =>
            flows.create(context, start: day, end: day, allDay: true, calendar: c.group),
        onReschedule: (o, start, end) => flows.reschedule(context, o, start, end),
      ),
      CalendarView.month => MonthView(
        controller: c,
        onOpen: (o) => flows.open(context, o),
        onCreate: (start, end, allDay) =>
            flows.create(context, start: start, end: end, calendar: c.group),
        onOpenDay: (day) {
          c.go(day);
          c.setView(CalendarView.day);
        },
        onMove: _moveToDay,
      ),
      CalendarView.schedule => ScheduleView(
        controller: c,
        onOpen: (o) => flows.open(context, o),
      ),
      CalendarView.year => YearView(
        controller: c,
        onOpenDay: (day) {
          c.go(day);
          c.setView(CalendarView.day);
        },
        onOpenMonth: (month) {
          c.go(month);
          c.setView(CalendarView.month);
        },
      ),
    };
  }

  /// An event dropped on another day keeps its time of day and length.
  void _moveToDay(Occurrence o, DateTime day) {
    final shift = daysBetween(o.start, day);
    if (shift == 0) return;
    final start = DateTime(
      o.start.year,
      o.start.month,
      o.start.day + shift,
      o.start.hour,
      o.start.minute,
    );
    final end = o.allDay
        ? DateTime(o.end.year, o.end.month, o.end.day + shift)
        : start.add(o.end.difference(o.start));
    unawaited(flows.reschedule(context, o, start, end));
  }

  Widget _results(BuildContext context) {
    final found = c.results;
    if (found == null) {
      return Center(
        child: Text(
          'Search titles, places and notes',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    if (found.isEmpty) {
      return Center(child: Text('No events match “${c.query}”'));
    }
    return ListView(
      children: [
        for (final o in found)
          EventTile(
            controller: c,
            occurrence: o,
            showDate: true,
            onTap: () => flows.open(context, o),
          ),
      ],
    );
  }

  // ---- calendars ------------------------------------------------------------------

  Widget _sidebar(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      _MiniMonth(controller: c),
      const SizedBox(height: 12),
      _calendarList(context),
    ],
  );

  Widget _calendarList(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
          child: Text(
            'My calendars',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        for (final info in c.calendars)
          _calendarRow(context, info),
        if (c.calendars.length == 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              'Private groups have calendars too. Open a group’s Calendar tab to plan with them; they show here when you join.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Widget _calendarRow(BuildContext context, CalendarInfo info) {
    final on = c.calendar.shown(info.id);
    final color = c.colorOfCalendar(info.id);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => c.setShown(info.id, !on),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Checkbox(
              value: on,
              activeColor: color,
              onChanged: (v) => c.setShown(info.id, v ?? true),
            ),
            Expanded(
              child: Text(
                info.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            PopupMenuButton<String?>(
              tooltip: 'Colour',
              icon: Icon(Icons.circle, size: 14, color: color),
              onSelected: (name) => c.setCalendarColor(info.id, name),
              itemBuilder: (context) => [
                for (final e in eventColors.entries)
                  PopupMenuItem(
                    value: e.key,
                    child: Row(
                      children: [
                        CircleAvatar(radius: 8, backgroundColor: e.value),
                        const SizedBox(width: 10),
                        Text(e.key[0].toUpperCase() + e.key.substring(1)),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showCalendars() {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => ListenableBuilder(
          listenable: c,
          builder: (context, _) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _MiniMonth(controller: c),
                  const SizedBox(height: 8),
                  _calendarList(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small month to jump to a day, with the focused week marked.
class _MiniMonth extends StatefulWidget {
  final CalendarController controller;
  const _MiniMonth({required this.controller});

  @override
  State<_MiniMonth> createState() => _MiniMonthState();
}

class _MiniMonthState extends State<_MiniMonth> {
  late DateTime month = DateTime(widget.controller.focus.year, widget.controller.focus.month);
  DateTime? lastFocus;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final scheme = Theme.of(context).colorScheme;
    // Follow the main view when it moves to another month.
    if (lastFocus != c.focus) {
      lastFocus = c.focus;
      month = DateTime(c.focus.year, c.focus.month);
    }
    final days = monthGridDays(month, c.firstWeekday);
    final weeks = monthWeeks(month, c.firstWeekday);
    final today = DateTime.now();
    final shown = c.gridDays;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                formatMonth(month),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Previous month',
              icon: const Icon(Icons.chevron_left, size: 20),
              onPressed: () => setState(() => month = addMonths(month, -1)),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Next month',
              icon: const Icon(Icons.chevron_right, size: 20),
              onPressed: () => setState(() => month = addMonths(month, 1)),
            ),
          ],
        ),
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Text(
                  weekdayShort(days[i].weekday).substring(0, 1),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
        for (var w = 0; w < weeks; w++)
          Row(
            children: [
              for (final day in days.sublist(w * 7, w * 7 + 7))
                Expanded(
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => c.go(day),
                    child: Container(
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: sameDay(day, today)
                            ? scheme.primary
                            : shown.any((d) => sameDay(d, day)) && c.view != CalendarView.month
                            ? scheme.primaryContainer
                            : null,
                        shape: sameDay(day, today) ? BoxShape.circle : BoxShape.rectangle,
                      ),
                      child: Text(
                        '${day.day}',
                        style: TextStyle(
                          fontSize: 12,
                          color: sameDay(day, today)
                              ? scheme.onPrimary
                              : day.month == month.month
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
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

class _SettingsDialog extends StatelessWidget {
  final CalendarController controller;
  const _SettingsDialog({required this.controller});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
      return AlertDialog(
        title: const Text('Calendar settings'),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Week starts on'),
                  trailing: DropdownButton<int>(
                    value: c.firstWeekday,
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('Monday')),
                      DropdownMenuItem(value: 6, child: Text('Saturday')),
                      DropdownMenuItem(value: 7, child: Text('Sunday')),
                    ],
                    onChanged: (v) => c.setPreferences(firstWeekday: v),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show weekends'),
                  value: c.showWeekends,
                  onChanged: (v) => c.setPreferences(showWeekends: v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show week numbers'),
                  value: c.weekNumbers,
                  onChanged: (v) => c.setPreferences(weekNumbers: v),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Default length'),
                  trailing: DropdownButton<int>(
                    value: const [15, 30, 45, 60, 90, 120].contains(c.defaultMinutes) ? c.defaultMinutes : 60,
                    items: const [
                      DropdownMenuItem(value: 15, child: Text('15 minutes')),
                      DropdownMenuItem(value: 30, child: Text('30 minutes')),
                      DropdownMenuItem(value: 45, child: Text('45 minutes')),
                      DropdownMenuItem(value: 60, child: Text('1 hour')),
                      DropdownMenuItem(value: 90, child: Text('90 minutes')),
                      DropdownMenuItem(value: 120, child: Text('2 hours')),
                    ],
                    onChanged: (v) => c.setPreferences(defaultMinutes: v),
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Default reminder'),
                  trailing: DropdownButton<int>(
                    value: const [-1, 0, 5, 10, 15, 30, 60, 1440].contains(c.defaultReminder) ? c.defaultReminder : 10,
                    items: [
                      const DropdownMenuItem(value: -1, child: Text('None')),
                      for (final m in const [0, 5, 10, 15, 30, 60, 1440])
                        DropdownMenuItem(
                          value: m,
                          child: Text(m == 0 ? 'At the time' : describeReminder(m).replaceAll(' before', '')),
                        ),
                    ],
                    onChanged: (v) => c.setPreferences(defaultReminder: v),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
        ],
      );
    },
  );
}
