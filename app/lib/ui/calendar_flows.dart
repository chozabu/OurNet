import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

import '../controllers/calendar_controller.dart';
import 'calendar_dates.dart';
import 'event_editor.dart';
import 'event_view.dart';

/// What people do with events, shared by the calendar screen and by whatever
/// opens an event from elsewhere (a link in chat, a notification).
class CalendarFlows {
  final CalendarController controller;

  /// Called to send an event link somewhere: the screen supplies a chat picker.
  final void Function(Occurrence)? shareLink;
  CalendarFlows(this.controller, {this.shareLink});

  late final EventActions actions = EventActions(
    edit: (o) => edit(_context!, o),
    duplicate: (o) => duplicate(_context!, o),
    shareLink: shareLink,
  );

  BuildContext? _context;

  /// Starts a new event; [start] and [end] pre-fill the form.
  Future<void> create(
    BuildContext context, {
    DateTime? start,
    DateTime? end,
    bool allDay = false,
    String? calendar,
  }) async {
    _context = context;
    final change = await showEventEditor(
      context,
      controller: controller,
      draft: controller.newDraft(start: start, end: end, allDay: allDay),
      timesChosen: start != null,
      calendar: calendar,
      speech: controller.speech,
      files: controller.files,
    );
    _saved(change, 'Event saved');
  }

  Future<void> edit(BuildContext context, Occurrence o) async {
    _context = context;
    final change = await showEventEditor(
      context,
      controller: controller,
      occurrence: o,
      speech: controller.speech,
      files: controller.files,
    );
    _saved(change, 'Event saved');
  }

  Future<void> duplicate(BuildContext context, Occurrence o) async {
    _context = context;
    final change = await showEventEditor(
      context,
      controller: controller,
      draft: EventDraft.of(o)..title = '${o.event.title} (copy)',
      calendar: o.calendar,
      speech: controller.speech,
      files: controller.files,
    );
    _saved(change, 'Event saved');
  }

  /// Opens an event's details.
  Future<void> open(BuildContext context, Occurrence o) {
    _context = context;
    return showEventDetails(
      context,
      controller: controller,
      occurrence: o,
      actions: actions,
    );
  }

  /// Opens the event a link names. Returns false when this device does not
  /// have it (yet), so the caller can say so.
  Future<bool> openLink(BuildContext context, String link) async {
    final parsed = Calendar.parseLink(link);
    if (parsed == null) return false;
    await controller.calendar.refresh();
    final o = controller.calendar.occurrence(
      parsed.calendar,
      parsed.entry,
      key: parsed.key,
      after: DateTime.now().subtract(const Duration(days: 1)),
    );
    if (o == null) return false;
    controller.go(o.start);
    if (context.mounted) unawaited(open(context, o));
    return true;
  }

  /// Moves or resizes an occurrence, asking how far the change reaches when
  /// it repeats.
  Future<void> reschedule(
    BuildContext context,
    Occurrence o,
    DateTime start,
    DateTime end,
  ) async {
    var scope = Scope.all;
    if (o.repeats) {
      final asked = await askScope(context, action: 'Move');
      if (asked == null) return;
      scope = asked;
    }
    final draft = EventDraft.of(o)
      ..start = start
      ..end = end;
    try {
      final change = await controller.calendar.update(o, draft, scope: scope);
      _saved(change, 'Event moved');
    } catch (e) {
      controller.notify('Could not move the event: $e');
    }
  }

  void _saved(Change? change, String message) {
    if (change == null) return;
    controller.notify(
      message,
      action: 'Undo',
      onAction: () => unawaited(controller.calendar.undo(change)),
    );
  }

  // ---- files ---------------------------------------------------------------------

  /// Reads an .ics file and adds its events to [calendar].
  Future<void> importFile(BuildContext context, String calendar) async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Choose a calendar file (.ics)',
      type: FileType.custom,
      allowedExtensions: const ['ics', 'ical'],
    );
    final path = picked.firstOrNull?.path;
    if (path == null || !context.mounted) return;
    try {
      final file = Ics.read(await File(path).readAsString());
      if (file.events.isEmpty) {
        controller.notify('No events found in that file.');
        return;
      }
      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Import events'),
          content: Text(
            'Add ${file.events.length} event${file.events.length == 1 ? '' : 's'} '
            'to ${controller.nameOf(calendar)}?'
            '${file.problems.isEmpty ? '' : '\n\n${file.problems.take(5).join('\n')}'}',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Import')),
          ],
        ),
      );
      if (go != true) return;
      controller.notify('Importing ${file.events.length} events…');
      final count = await controller.calendar.importIcs(calendar, file);
      controller.notify('Imported $count event${count == 1 ? '' : 's'}');
    } catch (e) {
      controller.notify('Could not import: $e');
    }
  }

  /// Events deleted in the last thirty days, to put back.
  Future<void> showDeleted(BuildContext context) async {
    await controller.calendar.refresh();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final list = controller.calendar.deleted().where(
            (e) => controller.group == null || e.calendar == controller.group,
          ).toList();
          return AlertDialog(
            title: const Text('Recently deleted'),
            content: SizedBox(
              width: 420,
              child: list.isEmpty
                  ? const Text('Events you delete stay here for 30 days.')
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final e in list)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              radius: 8,
                              backgroundColor: controller.colorOf(e),
                            ),
                            title: Text(eventTitle(e)),
                            subtitle: Text(
                              '${formatDay(e.start)} · ${controller.nameOf(e.calendar)}',
                            ),
                            trailing: TextButton(
                              onPressed: () async {
                                try {
                                  await controller.calendar.restoreEvent(e);
                                  controller.notify('Event restored');
                                } catch (error) {
                                  controller.notify('Could not restore: $error');
                                }
                                if (context.mounted) setState(() {});
                              },
                              child: const Text('Restore'),
                            ),
                          ),
                      ],
                    ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Saves [calendar] as an .ics file.
  Future<void> exportFile(String calendar) async {
    try {
      await controller.calendar.refresh();
      final text = controller.calendar.exportIcs(
        calendar,
        name: controller.nameOf(calendar),
      );
      final safe = controller.nameOf(calendar).replaceAll(RegExp(r'[^\w\- ]'), '').trim();
      final saved = await FilePicker.saveFile(
        fileName: '${safe.isEmpty ? 'calendar' : safe}.ics',
        bytes: utf8.encode(text),
      );
      if (saved != null) controller.notify('Calendar saved');
    } catch (e) {
      controller.notify('Could not export: $e');
    }
  }

  /// One event, as a file.
  Future<void> exportEvent(Occurrence o) async {
    try {
      final text = controller.calendar.exportEvent(o.master);
      final saved = await FilePicker.saveFile(
        fileName: '${eventTitle(o.master).replaceAll(RegExp(r'[^\w\- ]'), '')}.ics',
        bytes: utf8.encode(text),
      );
      if (saved != null) controller.notify('Event saved');
    } catch (e) {
      controller.notify('Could not export: $e');
    }
  }
}
