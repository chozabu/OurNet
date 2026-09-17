import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:timezone/data/latest.dart' as zones;
import 'package:timezone/timezone.dart' as tz;

import '../ui/note_markup.dart';
import '../ui/note_organise.dart' show nextReminder;
import 'coalesced_task.dart';
import 'notifications.dart';

/// Schedules this device's notifications for personal note reminders. The
/// reminders themselves sync between a person's devices; every device
/// schedules its own. While the app runs, a minute timer also shows anything
/// the operating system could not schedule (for example unpackaged Windows
/// builds).
class NoteReminders {
  final Notes notes;
  final Notifications notifications;
  late final CoalescedTask _task;
  StreamSubscription<void>? _changes;
  Timer? _timer;
  bool _started = false, _exact = false, _scheduling = true;
  final _scheduled = <String, String>{};

  NoteReminders(this.notes, this.notifications) {
    _task = CoalescedTask(sync, (e) => notifications.onError?.call('$e'));
  }

  Node get node => notes.node;

  /// A stable notification ID per note (FNV-1a), clear of other IDs.
  static int notificationId(String note) {
    var hash = 0x811c9dc5;
    for (final unit in note.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return 0x40000000 | (hash & 0x3fffffff);
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    // Earlier builds kept one row per occurrence shown; drop them once.
    if (node.store.setting('reminderKeysCompacted') != true) {
      node.store.removeSettingsUnder('reminderShown/');
      node.store.set('reminderKeysCompacted', true);
    }
    zones.initializeTimeZones();
    try {
      final zone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(zone.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.UTC);
    }
    if (!notifications.ready) await notifications.initialise();
    final android = notifications.plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    _exact = await android?.canScheduleExactNotifications() ?? false;
    _changes = node.changes.stream.listen((_) => _task.schedule());
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _due());
    _task.schedule();
    final launch = await notifications.plugin.getNotificationAppLaunchDetails();
    final payload = launch?.notificationResponse?.payload;
    if (launch?.didNotificationLaunchApp == true &&
        payload != null &&
        payload.startsWith('note:')) {
      notifications.onOpenNote?.call(payload.substring(5));
    }
  }

  /// Asks for notification permission when a reminder is first set.
  Future<void> requestPermission() async {
    await notifications.plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  Future<void> sync() async {
    await notes.refresh();
    final state = notes.state;
    final live = <String>{};
    for (final id in state.targets('reminder').toList()) {
      final reminder = state.reminder(id);
      if (reminder == null) continue;
      final note = await notes.get(id);
      if (note == null || note.deleted) continue;
      final next = nextReminder(reminder);
      if (next == null) continue;
      live.add(id);
      final title = note.label;
      final fingerprint =
          '${reminder['at']}|${reminder['repeat']}|$title|${next.millisecondsSinceEpoch}';
      if (_scheduled[id] == fingerprint) continue;
      await _cancel(id);
      if (await _schedule(id, next, reminder['repeat'] as String, note)) {
        _scheduled[id] = fingerprint;
      }
    }
    for (final id in _scheduled.keys.toList()) {
      if (!live.contains(id)) {
        await _cancel(id);
        _scheduled.remove(id);
      }
    }
  }

  NotificationDetails get _details => const NotificationDetails(
    android: AndroidNotificationDetails(
      'reminders',
      'Note reminders',
      channelDescription: 'Reminders you set on notes',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.private,
    ),
    windows: WindowsNotificationDetails(),
  );

  String _body(NoteDocument note) {
    final text = NoteMarkup.plain(
      [
        if (note.rawTitle.isNotEmpty) note.text,
        for (final c in note.checks.where((c) => !note.done(c)).take(5))
          '☐ ${note.itemText(c)}',
      ].where((l) => l.trim().isNotEmpty).join('\n'),
    );
    return text.substring(0, text.length.clamp(0, 200));
  }

  Future<bool> _schedule(
    String id,
    DateTime next,
    String repeat,
    NoteDocument note,
  ) async {
    if (!_scheduling) return false;
    try {
      await notifications.plugin.zonedSchedule(
        id: notificationId(id),
        title: note.label,
        body: _body(note),
        payload: 'note:$id',
        scheduledDate: tz.TZDateTime.from(next, tz.local),
        notificationDetails: _details,
        androidScheduleMode: _exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: switch (repeat) {
          'daily' => DateTimeComponents.time,
          'weekly' => DateTimeComponents.dayOfWeekAndTime,
          'monthly' => DateTimeComponents.dayOfMonthAndTime,
          'yearly' => DateTimeComponents.dateAndTime,
          _ => null,
        },
      );
      return true;
    } catch (_) {
      // Unsupported here: fall back to the in-app timer while OurNet runs.
      if (!Platform.isAndroid) _scheduling = false;
      return false;
    }
  }

  Future<void> _cancel(String id) async {
    try {
      await notifications.plugin.cancel(id: notificationId(id));
    } catch (_) {}
  }

  /// Shows due reminders the operating system was unable to schedule.
  Future<void> _due() async {
    if (_scheduling) return;
    final state = notes.state;
    final now = DateTime.now();
    for (final id in state.targets('reminder').toList()) {
      final reminder = state.reminder(id);
      if (reminder == null) continue;
      final previous = nextReminder(
        reminder,
        now.subtract(const Duration(minutes: 2)),
      );
      if (previous == null || previous.isAfter(now)) continue;
      // One key per note holding the occurrence last shown: a repeating
      // reminder would otherwise leave a settings row behind every time.
      final key = 'reminderShown/$id';
      final at = previous.millisecondsSinceEpoch;
      if (node.store.setting(key) == at) continue;
      node.store.set(key, at);
      final note = await notes.get(id);
      if (note == null || note.deleted) continue;
      await notifications.plugin.show(
        id: notificationId(id),
        title: note.label,
        body: _body(note),
        payload: 'note:$id',
        notificationDetails: _details,
      );
    }
  }

  void close() {
    _changes?.cancel();
    _timer?.cancel();
    _task.close();
  }
}
