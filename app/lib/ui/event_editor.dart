import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart' show Files;

import '../controllers/calendar_controller.dart';
import '../services/speech.dart';
import 'calendar_dates.dart';
import 'voice_recorder.dart';

/// How a series is edited, asked of the person when it repeats.
Future<Scope?> askScope(BuildContext context, {required String action}) =>
    showDialog<Scope>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('$action repeating event'),
        children: [
          for (final (scope, label) in const [
            (Scope.one, 'This event'),
            (Scope.following, 'This and following events'),
            (Scope.all, 'All events'),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, scope),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(label),
              ),
            ),
        ],
      ),
    );

/// The ways a new event can repeat, named for [start].
List<(String, Repeat?)> repeatPresets(DateTime start) {
  final nth = ((start.day - 1) ~/ 7) + 1;
  final lastInMonth = start.day + 7 > DateTime(start.year, start.month + 1, 0).day;
  const ordinals = ['', 'first', 'second', 'third', 'fourth', 'fifth'];
  final weekday = weekdayNames[start.weekday - 1];
  return [
    ('Does not repeat', null),
    ('Daily', const Repeat('daily')),
    ('Weekly on $weekday', const Repeat('weekly')),
    ('Monthly on day ${start.day}', const Repeat('monthly')),
    if (nth < 5)
      (
        'Monthly on the ${ordinals[nth]} $weekday',
        const Repeat('monthly', monthly: 'weekday'),
      ),
    if (lastInMonth)
      ('Monthly on the last $weekday', const Repeat('monthly', monthly: 'last')),
    (
      'Annually on ${monthNames[start.month - 1]} ${start.day}',
      const Repeat('yearly'),
    ),
    (
      'Every weekday (Monday to Friday)',
      const Repeat('weekly', days: [1, 2, 3, 4, 5]),
    ),
  ];
}

/// The custom repeat dialog: every N days, weeks, months or years, on chosen
/// weekdays, ending never, on a date, or after a number of times.
Future<Repeat?> showRepeatDialog(
  BuildContext context,
  DateTime start,
  Repeat? current,
) => showDialog<Repeat>(
  context: context,
  builder: (context) => _RepeatDialog(start: start, current: current),
);

class _RepeatDialog extends StatefulWidget {
  final DateTime start;
  final Repeat? current;
  const _RepeatDialog({required this.start, required this.current});

  @override
  State<_RepeatDialog> createState() => _RepeatDialogState();
}

class _RepeatDialogState extends State<_RepeatDialog> {
  late String freq;
  late int interval;
  late Set<int> days;
  late String monthly;
  String ends = 'never';
  late DateTime until;
  late int count;
  final intervalText = TextEditingController();
  final countText = TextEditingController();

  @override
  void initState() {
    super.initState();
    final r = widget.current;
    freq = r?.freq ?? 'weekly';
    interval = r?.interval ?? 1;
    days = {...(r?.days.isEmpty ?? true ? [widget.start.weekday] : r!.days)};
    monthly = r?.monthly ?? 'day';
    until = r?.until != null
        ? DateTime.fromMillisecondsSinceEpoch(r!.until!)
        : DateTime(widget.start.year, widget.start.month + 3, widget.start.day);
    count = r?.count ?? 10;
    ends = r?.count != null ? 'count' : r?.until != null ? 'until' : 'never';
    intervalText.text = '$interval';
    countText.text = '$count';
  }

  @override
  void dispose() {
    intervalText.dispose();
    countText.dispose();
    super.dispose();
  }

  Repeat result() {
    final every = (int.tryParse(intervalText.text) ?? 1).clamp(1, Repeat.maxInterval);
    final times = (int.tryParse(countText.text) ?? 1).clamp(1, Repeat.maxCount);
    return Repeat(
      freq,
      interval: every,
      days: freq == 'weekly' && !(days.length == 1 && days.first == widget.start.weekday)
          ? (days.toList()..sort())
          : const [],
      monthly: freq == 'monthly' ? monthly : 'day',
      until: ends == 'until'
          ? DateTime(until.year, until.month, until.day, 23, 59, 59).millisecondsSinceEpoch
          : null,
      count: ends == 'count' ? times : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final nth = ((widget.start.day - 1) ~/ 7) + 1;
    const ordinals = ['', 'first', 'second', 'third', 'fourth', 'fifth'];
    final weekday = weekdayNames[widget.start.weekday - 1];
    return AlertDialog(
      title: const Text('Custom repeat'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Repeat every'),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 64,
                    child: TextField(
                      controller: intervalText,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(isDense: true),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  DropdownButton<String>(
                    value: freq,
                    items: [
                      for (final (value, label) in const [
                        ('daily', 'day'),
                        ('weekly', 'week'),
                        ('monthly', 'month'),
                        ('yearly', 'year'),
                      ])
                        DropdownMenuItem(
                          value: value,
                          child: Text(intervalText.text == '1' ? label : '${label}s'),
                        ),
                    ],
                    onChanged: (v) => setState(() => freq = v!),
                  ),
                ],
              ),
              if (freq == 'weekly') ...[
                const SizedBox(height: 16),
                const Text('Repeat on'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      FilterChip(
                        label: Text(weekdayShort(d).substring(0, 2)),
                        tooltip: weekdayNames[d - 1],
                        selected: days.contains(d),
                        onSelected: (on) => setState(() {
                          if (on) {
                            days.add(d);
                          } else if (days.length > 1) {
                            days.remove(d);
                          }
                        }),
                      ),
                  ],
                ),
              ],
              if (freq == 'monthly') ...[
                const SizedBox(height: 12),
                DropdownButton<String>(
                  value: monthly,
                  isExpanded: true,
                  items: [
                    DropdownMenuItem(value: 'day', child: Text('Monthly on day ${widget.start.day}')),
                    if (nth < 5)
                      DropdownMenuItem(
                        value: 'weekday',
                        child: Text('Monthly on the ${ordinals[nth]} $weekday'),
                      ),
                    DropdownMenuItem(value: 'last', child: Text('Monthly on the last $weekday')),
                  ],
                  onChanged: (v) => setState(() => monthly = v!),
                ),
              ],
              const SizedBox(height: 16),
              const Text('Ends'),
              RadioGroup<String>(
                groupValue: ends,
                onChanged: (v) => setState(() => ends = v!),
                child: Column(
                  children: [
                    const RadioListTile<String>(
                      value: 'never',
                      title: Text('Never'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    RadioListTile<String>(
                      value: 'until',
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Row(
                        children: [
                          const Text('On '),
                          TextButton(
                            onPressed: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: until,
                                firstDate: widget.start,
                                lastDate: DateTime(widget.start.year + 100),
                              );
                              if (picked != null) {
                                setState(() {
                                  until = picked;
                                  ends = 'until';
                                });
                              }
                            },
                            child: Text(formatDay(until)),
                          ),
                        ],
                      ),
                    ),
                    RadioListTile<String>(
                      value: 'count',
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Row(
                        children: [
                          const Text('After '),
                          SizedBox(
                            width: 56,
                            child: TextField(
                              controller: countText,
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                              decoration: const InputDecoration(isDense: true),
                              onTap: () => setState(() => ends = 'count'),
                              onChanged: (_) => setState(() => ends = 'count'),
                            ),
                          ),
                          const Text(' times'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, result()), child: const Text('Done')),
      ],
    );
  }
}

/// Opens the event form: as a dialog on wide windows, a full page otherwise.
/// Saves through [controller] and returns what changed, or null if cancelled.
Future<Change?> showEventEditor(
  BuildContext context, {
  required CalendarController controller,
  Occurrence? occurrence,
  EventDraft? draft,
  bool? timesChosen,
  String? calendar,
  Speech? speech,
  Files? files,
}) {
  final page = EventEditor(
    timesChosen: timesChosen ?? draft != null,
    controller: controller,
    occurrence: occurrence,
    initial: draft,
    calendar: calendar,
    speech: speech,
    files: files,
  );
  if (MediaQuery.sizeOf(context).width >= 720) {
    return showDialog<Change>(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580, maxHeight: 760),
          child: page,
        ),
      ),
    );
  }
  return Navigator.of(context).push<Change>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => page),
  );
}

class EventEditor extends StatefulWidget {
  final CalendarController controller;

  /// The event being edited; null for a new one.
  final Occurrence? occurrence;
  final EventDraft? initial;

  /// Whether the times were picked (a slot, a copied event) rather than
  /// defaulted, which decides if a date typed into the title is taken up.
  final bool timesChosen;
  final String? calendar;
  final Speech? speech;
  final Files? files;
  const EventEditor({
    super.key,
    required this.controller,
    this.occurrence,
    this.initial,
    this.timesChosen = false,
    this.calendar,
    this.speech,
    this.files,
  });

  @override
  State<EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<EventEditor> {
  late EventDraft draft;
  late String calendarId;
  final title = TextEditingController();
  final location = TextEditingController();
  final notes = TextEditingController();
  final link = TextEditingController();
  final titleFocus = FocusNode();
  bool timeTouched = false, dirty = false, saving = false, dictating = false;
  String? error;
  QuickEvent? quick;

  CalendarController get c => widget.controller;
  bool get creating => widget.occurrence == null;
  Occurrence? get occurrence => widget.occurrence;

  @override
  void initState() {
    super.initState();
    draft =
        widget.initial ??
        (occurrence != null ? EventDraft.of(occurrence!) : c.newDraft());
    // A new event goes where the last one did, if that calendar is still
    // there; a group's own calendar always gets its own events.
    final last = c.node.store.setting('calLastCalendar');
    calendarId =
        occurrence?.calendar ??
        widget.calendar ??
        c.group ??
        (last is String && c.calendars.any((x) => x.id == last)
            ? last
            : Calendar.personal);
    title.text = draft.title;
    location.text = draft.location;
    notes.text = draft.description;
    link.text = draft.url;
    timeTouched = !creating || widget.timesChosen;
    if (creating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) titleFocus.requestFocus();
      });
    }
    title.addListener(_titleChanged);
  }

  @override
  void dispose() {
    title.dispose();
    location.dispose();
    notes.dispose();
    link.dispose();
    titleFocus.dispose();
    super.dispose();
  }

  void _titleChanged() {
    dirty = true;
    final found = creating && !timeTouched ? QuickAdd.parse(title.text) : null;
    if (found?.title != quick?.title || found?.start != quick?.start) {
      setState(() => quick = found);
    }
  }

  void _touch([VoidCallback? change]) {
    setState(() {
      dirty = true;
      error = null;
      change?.call();
    });
  }

  // ---- date and time ---------------------------------------------------------

  Future<void> _pickDate({required bool start}) async {
    final current = start ? draft.start : _shownEnd;
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(1970),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    _touch(() {
      timeTouched = true;
      if (start) {
        if (draft.allDay) {
          final days = _allDayLength;
          draft.start = dateOnly(picked);
          draft.end = addDays(draft.start, days);
        } else {
          final length = draft.end.difference(draft.start);
          final next = DateTime(
            picked.year,
            picked.month,
            picked.day,
            draft.start.hour,
            draft.start.minute,
          );
          draft.start = next;
          draft.end = next.add(length);
        }
      } else {
        final end = DateTime(picked.year, picked.month, picked.day, draft.end.hour, draft.end.minute);
        draft.end = draft.allDay ? addDays(dateOnly(picked), 1) : end;
      }
    });
  }

  int get _allDayLength => math.max(1, daysBetween(draft.start, draft.end));

  /// The end as people read it: an all-day event's last day, not the midnight
  /// after it.
  DateTime get _shownEnd => draft.allDay ? addDays(draft.end, -1) : draft.end;

  Future<void> _pickTime({required bool start}) async {
    final current = start ? draft.start : draft.end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (picked == null) return;
    _touch(() {
      timeTouched = true;
      if (start) {
        final length = draft.end.difference(draft.start);
        draft.start = DateTime(draft.start.year, draft.start.month, draft.start.day, picked.hour, picked.minute);
        draft.end = draft.start.add(length);
      } else {
        draft.end = DateTime(draft.end.year, draft.end.month, draft.end.day, picked.hour, picked.minute);
      }
    });
  }

  void _setAllDay(bool on) {
    _touch(() {
      timeTouched = true;
      if (on == draft.allDay) return;
      if (on) {
        final last = dateOnly(draft.end.isAfter(draft.start) ? draft.end.subtract(const Duration(milliseconds: 1)) : draft.start);
        draft.start = dateOnly(draft.start);
        draft.end = addDays(last, 1);
      } else {
        final day = draft.start;
        draft.start = DateTime(day.year, day.month, day.day, 9);
        draft.end = draft.start.add(Duration(minutes: c.defaultMinutes));
      }
      draft.allDay = on;
    });
  }

  String? get _problem {
    if (!draft.allDay && draft.end.isBefore(draft.start)) {
      return 'The event ends before it starts.';
    }
    if (draft.allDay && !draft.end.isAfter(draft.start)) {
      return 'The event ends before it starts.';
    }
    return null;
  }

  // ---- repeat ------------------------------------------------------------------

  String get _repeatLabel {
    final r = draft.repeat;
    if (r == null) return 'Does not repeat';
    for (final (label, preset) in repeatPresets(draft.start)) {
      if (preset != null && canonical(preset.toJson()) == canonical(r.toJson())) {
        return label;
      }
    }
    return r.describe();
  }

  Future<void> _chooseRepeat() async {
    final presets = repeatPresets(draft.start);
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final (i, (label, _)) in presets.indexed)
              ListTile(title: Text(label), onTap: () => Navigator.pop(context, i)),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Custom…'),
              onTap: () => Navigator.pop(context, -1),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == -1) {
      final custom = await showRepeatDialog(context, draft.start, draft.repeat);
      if (custom != null) _touch(() => draft.repeat = custom);
      return;
    }
    _touch(() => draft.repeat = presets[picked].$2);
  }

  // ---- reminders -----------------------------------------------------------------

  String _reminderText(int minutes) {
    if (!draft.allDay) return describeReminder(minutes);
    if (minutes == 0) return 'On the day at 9:00';
    return '${describeReminder(minutes)} at 9:00';
  }

  Future<void> _addReminder() async {
    final options = draft.allDay
        ? const [0, 1440, 2880, 10080]
        : const [0, 5, 10, 15, 30, 60, 120, 1440, 2880, 10080];
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final m in options.where((m) => !draft.reminders.contains(m)))
              ListTile(title: Text(_reminderText(m)), onTap: () => Navigator.pop(context, m)),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Custom…'),
              onTap: () async {
                final custom = await _customReminder();
                if (context.mounted) Navigator.pop(context, custom);
              },
            ),
          ],
        ),
      ),
    );
    if (picked != null && !draft.reminders.contains(picked)) {
      _touch(() => draft.reminders = [...draft.reminders, picked]..sort());
    }
  }

  Future<int?> _customReminder() async {
    final amount = TextEditingController(text: '1');
    var unit = 60;
    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Custom reminder'),
          content: Row(
            children: [
              SizedBox(
                width: 64,
                child: TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  autofocus: true,
                ),
              ),
              const SizedBox(width: 12),
              DropdownButton<int>(
                value: unit,
                items: const [
                  DropdownMenuItem(value: 1, child: Text('minutes')),
                  DropdownMenuItem(value: 60, child: Text('hours')),
                  DropdownMenuItem(value: 1440, child: Text('days')),
                  DropdownMenuItem(value: 10080, child: Text('weeks')),
                ],
                onChanged: (v) => setState(() => unit = v!),
              ),
              const Text(' before'),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final minutes = (int.tryParse(amount.text) ?? 0) * unit;
                Navigator.pop(context, minutes.clamp(0, 40320 * 4));
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), amount.dispose);
    return result;
  }

  // ---- dictation -----------------------------------------------------------------------

  /// Records a voice note. What was said becomes the event: a title with a
  /// date or time in it fills the form as quick-add does, and otherwise the
  /// words go into the notes. The recording is kept with the event.
  Future<void> _dictate() async {
    final speech = widget.speech;
    if (dictating) return;
    final recording = await recordVoice(context, speech: speech, message: true);
    if (recording == null || !mounted) return;
    setState(() {
      dictating = true;
      error = null;
    });
    try {
      var text = recording.transcript?.trim();
      if ((text == null || text.isEmpty) && speech != null && await speech.canTranscribe()) {
        try {
          text = await speech.transcribeFile(recording.path);
        } catch (e) {
          error = 'Saved the recording without text: $e';
        }
      }
      Json? stored;
      final files = widget.files;
      if (files != null) {
        stored = await files.store(recording.path);
      }
      if (!mounted) return;
      _touch(() {
        if (stored != null) {
          draft.carry
            ..removeWhere((k, _) => const ['chunks', 'chunkBytes', 'key', 'size', 'name', 'audio', 'transcript'].contains(k))
            ..addAll({
              'chunks': stored['chunks'],
              'chunkBytes': stored['chunkBytes'],
              'size': stored['size'],
              'name': 'Voice note.${recording.mime == 'audio/wav' ? 'wav' : 'm4a'}',
              if (stored['key'] != null) 'key': stored['key'],
              'audio': {'mime': recording.mime, 'duration': recording.duration},
              if (text != null && text.isNotEmpty) 'transcript': text,
            });
        }
        if (text != null && text.isNotEmpty) _applySpeech(text);
      });
    } catch (e) {
      if (mounted) setState(() => error = 'Could not keep the recording: $e');
    } finally {
      unawaited(File(recording.path).delete().then<void>((_) {}, onError: (Object _) {}));
      if (mounted) setState(() => dictating = false);
    }
  }

  void _applySpeech(String text) {
    final found = creating && !timeTouched ? QuickAdd.parse(text) : null;
    if (found != null && title.text.trim().isEmpty) {
      _apply(found);
      return;
    }
    if (title.text.trim().isEmpty) {
      final first = text.split(RegExp(r'(?<=[.!?])\s+')).first;
      title.text = first.length > 60 ? '${first.substring(0, 57)}…' : first;
    }
    notes.text = notes.text.trim().isEmpty ? text : '${notes.text.trim()}\n$text';
  }

  void _apply(QuickEvent found) {
    title.text = found.title;
    draft
      ..allDay = found.allDay
      ..start = found.start
      ..end = found.end;
    if (found.repeat != null) draft.repeat = found.repeat;
    if (!found.allDay && draft.reminders.isEmpty && c.defaultReminder >= 0) {
      draft.reminders = [c.defaultReminder];
    }
    timeTouched = true;
    quick = null;
  }

  // ---- saving ------------------------------------------------------------------------------

  EventDraft _result() => draft.copy()
    ..title = title.text
    ..location = location.text
    ..description = notes.text
    ..url = link.text.trim();

  Future<void> _save() async {
    if (saving) return;
    final problem = _problem;
    if (problem != null) {
      setState(() => error = problem);
      return;
    }
    var next = _result();
    // A date or time typed into a new event's title is what quick-add reads,
    // so saving applies it as well as offering it.
    final found = creating && !timeTouched ? QuickAdd.parse(next.title) : null;
    if (found != null && found.title.isNotEmpty) {
      next
        ..title = found.title
        ..allDay = found.allDay
        ..start = found.start
        ..end = found.end;
      if (found.repeat != null) next.repeat = found.repeat;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final calendar = c.calendar;
      Change change;
      if (creating) {
        change = await calendar.create(calendarId, next);
        c.node.store.set('calLastCalendar', calendarId);
      } else {
        final o = occurrence!;
        final moved = calendarId != o.calendar;
        var scope = Scope.all;
        if (o.repeats && !moved) {
          final asked = await askScope(context, action: 'Edit');
          if (asked == null) {
            if (mounted) setState(() => saving = false);
            return;
          }
          scope = asked;
        }
        change = await calendar.update(o, next, scope: scope);
        if (moved) {
          final entry = change.entry!;
          final now = calendar.event(o.calendar, entry);
          if (now != null) {
            final moveChange = await calendar.move(now, calendarId);
            change.parts.addAll(moveChange.parts);
            change.entry = moveChange.entry;
          }
        }
      }
      if (mounted) Navigator.pop(context, change);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = 'Could not save: $e';
        });
      }
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!dirty || saving) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
        ],
      ),
    );
    return discard == true;
  }

  // ---- building ----------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final calendars = c.calendars;
    final problem = _problem;
    final audio = draft.carry['audio'] as Map?;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) Navigator.pop(context);
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): _save,
        },
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: () async {
                if (await _confirmDiscard() && context.mounted) Navigator.pop(context);
              },
            ),
            title: Text(creating ? 'New event' : 'Edit event'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton(
                  onPressed: saving || problem != null ? null : _save,
                  child: saving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Save'),
                ),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              TextField(
                controller: title,
                focusNode: titleFocus,
                textCapitalization: TextCapitalization.sentences,
                style: Theme.of(context).textTheme.headlineSmall,
                decoration: const InputDecoration(
                  hintText: 'Add title',
                  border: UnderlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
              ),
              if (quick != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ActionChip(
                      avatar: const Icon(Icons.auto_awesome, size: 16),
                      label: Text(
                        quick!.allDay
                            ? '${formatDay(quick!.start)}${quick!.repeat != null ? ' · ${quick!.repeat!.describe()}' : ''}'
                            : '${formatDay(quick!.start)}, ${formatClock(context, quick!.start)} – ${formatClock(context, quick!.end)}${quick!.repeat != null ? ' · ${quick!.repeat!.describe()}' : ''}',
                      ),
                      onPressed: () => _touch(() => _apply(quick!)),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              _row(
                context,
                Icons.schedule,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('All day'),
                      value: draft.allDay,
                      onChanged: _setAllDay,
                    ),
                    _dateTimeRow(context, start: true),
                    _dateTimeRow(context, start: false),
                    if (problem != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(problem, style: TextStyle(color: scheme.error, fontSize: 12.5)),
                      ),
                  ],
                ),
              ),
              _row(
                context,
                Icons.repeat,
                Builder(
                  builder: (context) => InkWell(
                    onTap: _chooseRepeat,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        children: [
                          Expanded(child: Text(_repeatLabel)),
                          const Icon(Icons.arrow_drop_down),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _row(
                context,
                Icons.notifications_none,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final m in draft.reminders)
                      Row(
                        children: [
                          Expanded(child: Text(_reminderText(m))),
                          IconButton(
                            tooltip: 'Remove reminder',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => _touch(() => draft.reminders = [...draft.reminders]..remove(m)),
                          ),
                        ],
                      ),
                    if (draft.reminders.length < Calendar.maxReminders)
                      TextButton(
                        onPressed: _addReminder,
                        child: const Text('Add notification'),
                      ),
                  ],
                ),
              ),
              _row(
                context,
                Icons.calendar_today_outlined,
                DropdownButton<String>(
                  value: calendars.any((x) => x.id == calendarId) ? calendarId : Calendar.personal,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final info in calendars.isEmpty
                        ? const [CalendarInfo(Calendar.personal, 'My calendar', true)]
                        : calendars)
                      DropdownMenuItem(
                        value: info.id,
                        child: Row(
                          children: [
                            CircleAvatar(radius: 6, backgroundColor: c.colorOfCalendar(info.id)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                info.personal ? info.name : '${info.name} (group)',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  onChanged: c.group != null
                      ? null
                      : (v) => _touch(() => calendarId = v!),
                ),
              ),
              if (calendarId != Calendar.personal)
                Padding(
                  padding: const EdgeInsets.only(left: 40, bottom: 4),
                  child: Text(
                    'Everyone in ${c.nameOf(calendarId)} can see and change this event.',
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                ),
              _row(
                context,
                Icons.place_outlined,
                TextField(
                  controller: location,
                  onChanged: (_) => dirty = true,
                  decoration: const InputDecoration(
                    hintText: 'Add location',
                    border: InputBorder.none,
                  ),
                ),
              ),
              _row(
                context,
                Icons.notes,
                Column(
                  children: [
                    TextField(
                      controller: notes,
                      onChanged: (_) => dirty = true,
                      minLines: 3,
                      maxLines: 10,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Add description',
                        border: InputBorder.none,
                      ),
                    ),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: dictating ? null : _dictate,
                          icon: dictating
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.mic_none),
                          label: Text(audio == null ? 'Dictate' : 'Record again'),
                        ),
                        const SizedBox(width: 12),
                        if (audio != null)
                          Expanded(
                            child: Row(
                              children: [
                                const Icon(Icons.graphic_eq, size: 18),
                                const SizedBox(width: 6),
                                Text('Voice note ${_duration(audio['duration'])}'),
                                IconButton(
                                  tooltip: 'Remove voice note',
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: () => _touch(
                                    () => draft.carry.removeWhere(
                                      (k, _) => const ['chunks', 'chunkBytes', 'key', 'size', 'name', 'audio', 'transcript'].contains(k),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              _row(
                context,
                Icons.link,
                TextField(
                  controller: link,
                  onChanged: (_) => dirty = true,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    hintText: 'Add link',
                    border: InputBorder.none,
                  ),
                ),
              ),
              _row(
                context,
                Icons.palette_outlined,
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in [(null as String?, c.colorOfCalendar(calendarId)), ...eventColors.entries.map((e) => (e.key as String?, e.value))])
                      Tooltip(
                        message: entry.$1 ?? 'Calendar colour',
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => _touch(() => draft.color = entry.$1),
                          child: CircleAvatar(
                            radius: 13,
                            backgroundColor: entry.$2,
                            child: draft.color == entry.$1
                                ? Icon(Icons.check, size: 16, color: onColor(entry.$2))
                                : entry.$1 == null
                                ? Icon(Icons.refresh, size: 14, color: onColor(entry.$2))
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              _row(
                context,
                Icons.event_busy_outlined,
                Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: true, label: Text('Busy')),
                      ButtonSegment(value: false, label: Text('Free')),
                    ],
                    selected: {draft.busy},
                    onSelectionChanged: (s) => _touch(() => draft.busy = s.first),
                  ),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(error!, style: TextStyle(color: scheme.error)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _duration(Object? ms) {
    final total = ((ms as int? ?? 0) / 1000).round();
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  Widget _row(BuildContext context, IconData icon, Widget child) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, right: 16),
          child: Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        Expanded(child: child),
      ],
    ),
  );

  Widget _dateTimeRow(BuildContext context, {required bool start}) {
    final date = start ? draft.start : _shownEnd;
    return Row(
      children: [
        SizedBox(width: 42, child: Text(start ? 'From' : 'To', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
        TextButton(
          onPressed: () => _pickDate(start: start),
          child: Text(formatDay(date)),
        ),
        if (!draft.allDay)
          TextButton(
            onPressed: () => _pickTime(start: start),
            child: Text(formatClock(context, start ? draft.start : draft.end, short: false)),
          ),
      ],
    );
  }
}
