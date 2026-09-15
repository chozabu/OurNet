import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

/// A reminder chosen in [pickReminder]; [at] is null to remove it.
typedef ReminderChoice = ({DateTime? at, String repeat});

const repeatNames = {
  'none': 'Does not repeat',
  'daily': 'Daily',
  'weekly': 'Weekly',
  'monthly': 'Monthly',
  'yearly': 'Yearly',
};

/// The next time a reminder fires at or after [now]; null when a one-off
/// reminder has passed.
DateTime? nextReminder(Json reminder, [DateTime? now]) {
  final at = DateTime.fromMillisecondsSinceEpoch(reminder['at'] as int);
  final current = now ?? DateTime.now();
  final repeat = reminder['repeat'] as String? ?? 'none';
  if (!at.isBefore(current) || repeat == 'none') {
    return at.isBefore(current) ? null : at;
  }
  var next = at;
  var step = 0;
  while (next.isBefore(current) && step < 100000) {
    step++;
    next = switch (repeat) {
      'daily' => DateTime(at.year, at.month, at.day + step, at.hour, at.minute),
      'weekly' => DateTime(
        at.year,
        at.month,
        at.day + 7 * step,
        at.hour,
        at.minute,
      ),
      'monthly' => DateTime(
        at.year,
        at.month + step,
        at.day,
        at.hour,
        at.minute,
      ),
      _ => DateTime(at.year + step, at.month, at.day, at.hour, at.minute),
    };
  }
  return next;
}

/// "Tomorrow, 08:00", "Mon 21 Sep, 18:00" and so on, with a repeat suffix.
String describeReminder(BuildContext context, Json reminder) {
  final localizations = MaterialLocalizations.of(context);
  final at = DateTime.fromMillisecondsSinceEpoch(reminder['at'] as int);
  final shown = nextReminder(reminder) ?? at;
  final today = DateUtils.dateOnly(DateTime.now());
  final day = DateUtils.dateOnly(shown);
  final time = localizations.formatTimeOfDay(
    TimeOfDay.fromDateTime(shown),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  final date = day == today
      ? 'Today'
      : day == today.add(const Duration(days: 1))
      ? 'Tomorrow'
      : day == today.subtract(const Duration(days: 1))
      ? 'Yesterday'
      : localizations.formatMediumDate(shown);
  final repeat = reminder['repeat'] as String? ?? 'none';
  return '$date, $time${repeat == 'none' ? '' : ' · ${repeatNames[repeat]}'}';
}

/// Keep-style reminder presets plus a custom date, time and repeat.
Future<ReminderChoice?> pickReminder(BuildContext context, Json? existing) {
  final now = DateTime.now();
  DateTime at(int days, int hour) =>
      DateTime(now.year, now.month, now.day + days, hour);
  final laterToday = at(0, now.hour < 18 ? 18 : 20);
  final nextWeek = at(
    (DateTime.monday - now.weekday + 7) % 7 +
        (now.weekday == DateTime.monday ? 7 : 0),
    8,
  );
  return showModalBottomSheet<ReminderChoice>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final localizations = MaterialLocalizations.of(context);
      String time(DateTime value) => localizations.formatTimeOfDay(
        TimeOfDay.fromDateTime(value),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Remind me')),
            if (now.hour < 20)
              ListTile(
                leading: const Icon(Icons.schedule),
                title: const Text('Later today'),
                trailing: Text(time(laterToday)),
                onTap: () =>
                    Navigator.pop(context, (at: laterToday, repeat: 'none')),
              ),
            ListTile(
              leading: const Icon(Icons.wb_sunny_outlined),
              title: const Text('Tomorrow'),
              trailing: Text(time(at(1, 8))),
              onTap: () =>
                  Navigator.pop(context, (at: at(1, 8), repeat: 'none')),
            ),
            ListTile(
              leading: const Icon(Icons.date_range),
              title: const Text('Next week'),
              trailing: Text(
                '${localizations.formatShortMonthDay(nextWeek)}, ${time(nextWeek)}',
              ),
              onTap: () =>
                  Navigator.pop(context, (at: nextWeek, repeat: 'none')),
            ),
            ListTile(
              leading: const Icon(Icons.edit_calendar_outlined),
              title: const Text('Pick date & time'),
              onTap: () async {
                final chosen = await _custom(context, existing);
                if (chosen != null && context.mounted) {
                  Navigator.pop(context, chosen);
                }
              },
            ),
            if (existing != null)
              ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: const Text('Remove reminder'),
                onTap: () => Navigator.pop(context, (at: null, repeat: 'none')),
              ),
          ],
        ),
      );
    },
  );
}

Future<ReminderChoice?> _custom(BuildContext context, Json? existing) async {
  final initial = existing == null
      ? DateTime.now().add(const Duration(hours: 1))
      : DateTime.fromMillisecondsSinceEpoch(existing['at'] as int);
  var date = DateUtils.dateOnly(initial);
  var time = TimeOfDay.fromDateTime(initial);
  var repeat = existing?['repeat'] as String? ?? 'none';
  return showDialog<ReminderChoice>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, change) {
        final localizations = MaterialLocalizations.of(context);
        return AlertDialog(
          title: const Text('Pick date & time'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_today),
                title: Text(localizations.formatFullDate(date)),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: date,
                    firstDate: DateUtils.dateOnly(
                      DateTime.now(),
                    ).subtract(const Duration(days: 1)),
                    lastDate: DateTime.now().add(const Duration(days: 3650)),
                  );
                  if (picked != null) change(() => date = picked);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.access_time),
                title: Text(localizations.formatTimeOfDay(time)),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: time,
                  );
                  if (picked != null) change(() => time = picked);
                },
              ),
              DropdownButtonFormField<String>(
                initialValue: repeat,
                decoration: const InputDecoration(labelText: 'Repeat'),
                items: [
                  for (final entry in repeatNames.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: (value) => change(() => repeat = value ?? 'none'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, (
                at: DateTime(
                  date.year,
                  date.month,
                  date.day,
                  time.hour,
                  time.minute,
                ),
                repeat: repeat,
              )),
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
}

/// Labels for [notes], applied as they are ticked. New labels can be created
/// by typing a name that does not exist yet.
Future<void> editNoteLabels(
  BuildContext context,
  NoteState state,
  List<String> notes, {
  void Function(String message)? notice,
}) => showDialog<void>(
  context: context,
  builder: (context) =>
      _LabelPicker(state: state, notes: notes, notice: notice),
);

class _LabelPicker extends StatefulWidget {
  final NoteState state;
  final List<String> notes;
  final void Function(String message)? notice;
  const _LabelPicker({required this.state, required this.notes, this.notice});
  @override
  State<_LabelPicker> createState() => _LabelPickerState();
}

class _LabelPickerState extends State<_LabelPicker> {
  final search = TextEditingController();
  bool busy = false;

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      widget.notice?.call('$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.state.labels;
    final query = search.text.trim().toLowerCase();
    final shown = labels.entries
        .where((e) => e.value.toLowerCase().contains(query))
        .toList();
    final exists = labels.values.any((v) => v.toLowerCase() == query);
    return AlertDialog(
      title: const Text('Label note'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: search,
              autofocus: true,
              maxLength: 50,
              decoration: const InputDecoration(
                hintText: 'Enter label name',
                prefixIcon: Icon(Icons.search),
                counterText: '',
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (value) {
                if (value.trim().isNotEmpty && !exists) create(value);
              },
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final entry in shown)
                    CheckboxListTile(
                      value: widget.notes.every(
                        (n) => widget.state.labelsOf(n).contains(entry.key),
                      ),
                      tristate: false,
                      title: Text(entry.value),
                      secondary: const Icon(Icons.label_outline),
                      onChanged: busy
                          ? null
                          : (value) => run(
                              () => widget.state.label(
                                widget.notes,
                                entry.key,
                                value == true,
                              ),
                            ),
                    ),
                  if (query.isNotEmpty && !exists)
                    ListTile(
                      leading: const Icon(Icons.add),
                      title: Text('Create "${search.text.trim()}"'),
                      onTap: busy ? null : () => create(search.text),
                    ),
                  if (labels.isEmpty && query.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'Labels are private to you and sync between your own devices.',
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  void create(String name) => run(() async {
    final id = await widget.state.createLabel(name);
    await widget.state.label(widget.notes, id, true);
    search.clear();
  });
}

/// Create, rename and delete labels.
Future<void> manageLabels(
  BuildContext context,
  NoteState state, {
  void Function(String message)? notice,
}) => showDialog<void>(
  context: context,
  builder: (context) => _LabelManager(state: state, notice: notice),
);

class _LabelManager extends StatefulWidget {
  final NoteState state;
  final void Function(String message)? notice;
  const _LabelManager({required this.state, this.notice});
  @override
  State<_LabelManager> createState() => _LabelManagerState();
}

class _LabelManagerState extends State<_LabelManager> {
  final create = TextEditingController();
  final editing = <String, TextEditingController>{};

  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      widget.notice?.call('$e');
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    create.dispose();
    for (final c in editing.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.state.labels;
    return AlertDialog(
      title: const Text('Edit labels'),
      content: SizedBox(
        width: 380,
        child: ListView(
          shrinkWrap: true,
          children: [
            TextField(
              controller: create,
              maxLength: 50,
              decoration: InputDecoration(
                hintText: 'Create new label',
                counterText: '',
                prefixIcon: const Icon(Icons.add),
                suffixIcon: IconButton(
                  tooltip: 'Create label',
                  icon: const Icon(Icons.check),
                  onPressed: () => run(() async {
                    if (create.text.trim().isEmpty) return;
                    await widget.state.createLabel(create.text);
                    create.clear();
                  }),
                ),
              ),
              onSubmitted: (value) => run(() async {
                if (value.trim().isEmpty) return;
                await widget.state.createLabel(value);
                create.clear();
              }),
            ),
            for (final entry in labels.entries)
              Row(
                children: [
                  IconButton(
                    tooltip: 'Delete label',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          content: Text(
                            'Delete "${entry.value}"? It is removed from all notes; the notes stay.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        await run(() => widget.state.deleteLabel(entry.key));
                      }
                    },
                  ),
                  Expanded(
                    child: TextField(
                      controller: editing.putIfAbsent(
                        entry.key,
                        () => TextEditingController(text: entry.value),
                      ),
                      maxLength: 50,
                      decoration: const InputDecoration(counterText: ''),
                      onSubmitted: (value) =>
                          run(() => widget.state.renameLabel(entry.key, value)),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Rename label',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => run(
                      () => widget.state.renameLabel(
                        entry.key,
                        editing[entry.key]!.text,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// Small chips shown under a note's content and on cards.
class NoteChips extends StatelessWidget {
  final List<String> labels;
  final Json? reminder;
  final void Function(String label)? onRemoveLabel;
  final VoidCallback? onReminder;
  final VoidCallback? onRemoveReminder;
  final bool dense;
  const NoteChips({
    super.key,
    required this.labels,
    this.reminder,
    this.onRemoveLabel,
    this.onReminder,
    this.onRemoveReminder,
    this.dense = false,
  });
  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty && reminder == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final passed = reminder != null && nextReminder(reminder!) == null;
    final style = dense ? theme.textTheme.labelSmall : null;
    Widget chip({
      required Widget label,
      Widget? avatar,
      VoidCallback? onTap,
      VoidCallback? onDeleted,
    }) => dense
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
              color: theme.colorScheme.surface.withValues(alpha: .35),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (avatar != null) ...[avatar, const SizedBox(width: 4)],
                DefaultTextStyle.merge(style: style, child: label),
              ],
            ),
          )
        : InputChip(
            avatar: avatar,
            label: label,
            onPressed: onTap,
            onDeleted: onDeleted,
            visualDensity: VisualDensity.compact,
          );
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (reminder != null)
          chip(
            avatar: Icon(
              passed ? Icons.alarm_off : Icons.alarm,
              size: dense ? 14 : 18,
            ),
            label: Text(
              describeReminder(context, reminder!),
              style: passed
                  ? const TextStyle(decoration: TextDecoration.lineThrough)
                  : null,
            ),
            onTap: onReminder,
            onDeleted: onRemoveReminder,
          ),
        for (final label in labels)
          chip(
            label: Text(label),
            onDeleted: onRemoveLabel == null
                ? null
                : () => onRemoveLabel!(label),
          ),
      ],
    );
  }
}
