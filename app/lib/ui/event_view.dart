import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/calendar_controller.dart';
import 'calendar_dates.dart';
import 'event_editor.dart';
import 'message_text.dart';
import 'note_attachments.dart' show AudioClip;

/// What the details sheet asks of the screen that opened it.
class EventActions {
  final void Function(Occurrence) edit;
  final void Function(Occurrence) duplicate;
  final void Function(Occurrence)? shareLink;
  const EventActions({
    required this.edit,
    required this.duplicate,
    this.shareLink,
  });
}

/// Shows an event's details: as a dialog on wide windows, a sheet otherwise.
Future<void> showEventDetails(
  BuildContext context, {
  required CalendarController controller,
  required Occurrence occurrence,
  required EventActions actions,
}) {
  final body = EventDetails(
    controller: controller,
    occurrence: occurrence,
    actions: actions,
  );
  if (MediaQuery.sizeOf(context).width >= 720) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 720),
          child: body,
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => body,
  );
}

class EventDetails extends StatefulWidget {
  final CalendarController controller;
  final Occurrence occurrence;
  final EventActions actions;
  const EventDetails({
    super.key,
    required this.controller,
    required this.occurrence,
    required this.actions,
  });

  @override
  State<EventDetails> createState() => _EventDetailsState();
}

class _EventDetailsState extends State<EventDetails> {
  late Occurrence occurrence = widget.occurrence;
  Future<List<String>>? members;
  bool busy = false;

  CalendarController get c => widget.controller;
  CalEvent get e => occurrence.event;
  bool get group => occurrence.calendar != Calendar.personal;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    if (group) members = c.calendar.members(occurrence.calendar);
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    super.dispose();
  }

  /// Keeps the sheet current when someone changes the event meanwhile.
  void _changed() {
    final fresh = c.calendar.occurrence(
      occurrence.calendar,
      occurrence.entry,
      key: occurrence.key.isEmpty ? null : occurrence.key,
    );
    if (fresh == null) {
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      return;
    }
    if (mounted) setState(() => occurrence = fresh);
  }

  Future<void> _delete() async {
    var scope = Scope.all;
    if (occurrence.repeats) {
      final asked = await askScope(context, action: 'Delete');
      if (asked == null) return;
      scope = asked;
    }
    setState(() => busy = true);
    try {
      final change = await c.calendar.delete(occurrence, scope: scope);
      if (!mounted) return;
      Navigator.pop(context);
      c.notify(
        'Event deleted',
        action: 'Undo',
        onAction: () => unawaited(c.calendar.undo(change)),
      );
    } catch (error) {
      if (mounted) {
        setState(() => busy = false);
        c.notify('Could not delete: $error');
      }
    }
  }

  Future<void> _respond(Rsvp? answer) async {
    // A repeating event is answered for every occurrence unless this one is
    // asked about specifically.
    String? key;
    if (occurrence.repeats) {
      final asked = await askScope(context, action: 'Reply to');
      if (asked == null) return;
      key = asked == Scope.one ? occurrence.key : null;
    }
    try {
      await c.calendar.respond(occurrence.calendar, occurrence.entry, answer, key: key);
      if (mounted) setState(() {});
    } catch (error) {
      c.notify('Could not send your answer: $error');
    }
  }

  /// Reminders for a group's event are the event's, but each person can have
  /// their own instead, which follows them to their other devices.
  Future<void> _myReminders() async {
    final own = c.calendar.reminderOverride(occurrence.entry);
    final options = e.allDay
        ? const [0, 1440, 2880, 10080]
        : const [0, 5, 10, 15, 30, 60, 120, 1440, 2880, 10080];
    var custom = own != null;
    final picked = <int>{...(own ?? e.reminders)};
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('My reminders'),
          content: SizedBox(
            width: 340,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioGroup<bool>(
                    groupValue: custom,
                    onChanged: (v) => setState(() => custom = v!),
                    child: const Column(
                      children: [
                        RadioListTile<bool>(
                          value: false,
                          dense: true,
                          title: Text('Use the event’s reminders'),
                        ),
                        RadioListTile<bool>(
                          value: true,
                          dense: true,
                          title: Text('Choose my own'),
                        ),
                      ],
                    ),
                  ),
                  if (custom)
                    for (final m in options)
                      CheckboxListTile(
                        dense: true,
                        value: picked.contains(m),
                        title: Text(
                          e.allDay && m == 0
                              ? 'On the day at 9:00'
                              : describeReminder(m),
                        ),
                        onChanged: (on) => setState(() {
                          if (on == true) {
                            picked.add(m);
                          } else {
                            picked.remove(m);
                          }
                        }),
                      ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    try {
      await c.calendar.setReminderOverride(
        occurrence.entry,
        custom ? (picked.toList()..sort()) : null,
      );
      c.changed();
    } catch (error) {
      c.notify('Could not save: $error');
    }
  }

  void _copyLink() {
    final link = Calendar.link(
      occurrence.calendar,
      occurrence.entry,
      key: occurrence.repeats ? occurrence.key : null,
    );
    unawaited(Clipboard.setData(ClipboardData(text: link)));
    c.notify(
      group
          ? 'Link copied. People in ${c.nameOf(occurrence.calendar)} can open it.'
          : 'Link copied. Only you can open a link to a personal event.',
    );
  }

  Future<void> _openMap() async {
    final uri = Uri.https('www.openstreetmap.org', '/search', {'query': e.location});
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = c.colorOf(e);
    final answers = group
        ? c.calendar.rsvps(occurrence.calendar, occurrence.entry, occurrence.key)
        : const <String, Rsvp>{};
    final mine = answers[c.node.person];
    final reminders = c.calendar.remindersFor(e);
    final link = e.url.isEmpty ? null : MessageText.linkUri(e.url);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.delete): () {
          if (!busy) unawaited(_delete());
        },
        const SingleActivator(LogicalKeyboardKey.keyE): () {
          if (busy) return;
          Navigator.pop(context);
          widget.actions.edit(occurrence);
        },
      },
      child: Focus(
        autofocus: true,
        child: _body(context, scheme, color, answers, mine, reminders, link),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    ColorScheme scheme,
    Color color,
    Map<String, Rsvp> answers,
    Rsvp? mine,
    List<int> reminders,
    Uri? link,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Spacer(),
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined),
                onPressed: busy
                    ? null
                    : () {
                        Navigator.pop(context);
                        widget.actions.edit(occurrence);
                      },
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: busy ? null : _delete,
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (v) {
                  switch (v) {
                    case 'link':
                      _copyLink();
                    case 'share':
                      Navigator.pop(context);
                      widget.actions.shareLink?.call(occurrence);
                    case 'duplicate':
                      Navigator.pop(context);
                      widget.actions.duplicate(occurrence);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'link', child: Text('Copy link')),
                  if (widget.actions.shareLink != null)
                    const PopupMenuItem(value: 'share', child: Text('Send link in a chat')),
                  const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
                ],
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 16,
                height: 16,
                margin: const EdgeInsets.only(top: 9, right: 14),
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
              ),
              Expanded(
                child: SelectableText(
                  eventTitle(e),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _line(context, Icons.schedule, describeWhen(context, occurrence)),
          if (occurrence.repeats)
            _line(context, Icons.repeat, occurrence.master.repeat!.describe()),
          if (e.location.isNotEmpty)
            _line(
              context,
              Icons.place_outlined,
              e.location,
              trailing: TextButton(onPressed: _openMap, child: const Text('Map')),
            ),
          if (link != null)
            _line(
              context,
              Icons.link,
              e.url,
              onTap: () => unawaited(
                launchUrl(link, mode: LaunchMode.externalApplication).catchError((Object _) => false),
              ),
            ),
          if (e.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 14),
                    child: Icon(Icons.notes, size: 20, color: scheme.onSurfaceVariant),
                  ),
                  Expanded(child: MessageText(e.description)),
                ],
              ),
            ),
          if (e.hasAudio && c.files != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: AudioClip(
                files: c.files!,
                object: e.object,
                payload: e.data,
                meta: Map<String, dynamic>.from(e.data['audio'] as Map),
                editable: false,
                transcript: e.transcript.isEmpty
                    ? const SizedBox.shrink()
                    : SelectableText(e.transcript),
              ),
            )
          else if (e.transcript.isNotEmpty && e.description.isEmpty)
            _line(context, Icons.mic_none, e.transcript),
          if (reminders.isNotEmpty || group)
            _line(
              context,
              Icons.notifications_none,
              reminders.isEmpty
                  ? 'No reminders'
                  : [
                      for (final m in reminders)
                        e.allDay
                            ? '${describeReminder(m)} at 9:00'
                            : describeReminder(m),
                    ].join('\n'),
              onTap: group ? _myReminders : null,
              trailing: group && c.calendar.reminderOverride(occurrence.entry) != null
                  ? Text(
                      'Mine',
                      style: TextStyle(fontSize: 12, color: scheme.primary),
                    )
                  : null,
            ),
          _line(
            context,
            Icons.calendar_today_outlined,
            group
                ? '${c.nameOf(occurrence.calendar)} · added by ${c.personName(e.author)}'
                : c.nameOf(occurrence.calendar),
            dot: c.colorOfCalendar(occurrence.calendar),
          ),
          if (group) ...[
            const Divider(height: 28),
            Text('Going?', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final (answer, label) in const [
                  (Rsvp.yes, 'Yes'),
                  (Rsvp.maybe, 'Maybe'),
                  (Rsvp.no, 'No'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: mine == answer,
                    onSelected: (on) => _respond(on ? answer : null),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            FutureBuilder<List<String>>(
              future: members,
              builder: (context, snapshot) {
                final people = snapshot.data ?? const <String>[];
                if (people.isEmpty) return const SizedBox.shrink();
                final yes = answers.values.where((a) => a == Rsvp.yes).length;
                final maybe = answers.values.where((a) => a == Rsvp.maybe).length;
                final no = answers.values.where((a) => a == Rsvp.no).length;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$yes yes · $maybe maybe · $no no · ${people.length - answers.length} not answered',
                      style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    for (final person in people)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Icon(
                              switch (answers[person]) {
                                Rsvp.yes => Icons.check_circle,
                                Rsvp.no => Icons.cancel,
                                Rsvp.maybe => Icons.help,
                                null => Icons.radio_button_unchecked,
                              },
                              size: 18,
                              color: switch (answers[person]) {
                                Rsvp.yes => Colors.green,
                                Rsvp.no => scheme.error,
                                Rsvp.maybe => Colors.orange,
                                null => scheme.onSurfaceVariant,
                              },
                            ),
                            const SizedBox(width: 10),
                            Expanded(child: Text(c.personName(person))),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _line(
    BuildContext context,
    IconData icon,
    String text, {
    Widget? trailing,
    VoidCallback? onTap,
    Color? dot,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 14, top: 1),
            child: dot != null
                ? Padding(
                    padding: const EdgeInsets.all(4),
                    child: CircleAvatar(radius: 6, backgroundColor: dot),
                  )
                : Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          ),
          Expanded(
            child: Text(
              text,
              style: onTap == null ? null : TextStyle(color: scheme.primary),
            ),
          ),
          ?trailing,
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}
