import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:timezone/data/latest.dart' as zones;
import 'package:timezone/timezone.dart' as tz;

import '../controllers/calendar_controller.dart';
import '../ui/calendar_dates.dart';
import 'coalesced_task.dart';
import 'messaging.dart' show chatMuted;
import 'notifications.dart';

/// Notifications for calendar events, scheduled on this device.
///
/// The reminders themselves are part of the events and sync with them; every
/// device schedules its own. Only the next few days are scheduled, one pass
/// per change and one per hour, so cost follows what is coming up and not the
/// length of the calendar. Where the system cannot schedule (unpackaged
/// Windows builds) a minute timer shows anything that fell due while OurNet
/// ran.
class CalendarReminders {
  final CalendarController controller;
  final Notifications notifications;
  late final CoalescedTask _task;
  Timer? _timer;
  bool _started = false, _exact = false, _scheduling = true, _closed = false;
  final _scheduled = <int, String>{};
  List<DueReminder> _upcoming = const [];

  /// How far ahead to schedule, and at most how many notifications at once.
  static const horizon = Duration(days: 14);
  static const limit = 48;
  static const range = 0x04000000;

  CalendarReminders(this.controller, this.notifications) {
    _task = CoalescedTask(
      sync,
      (e) => notifications.onError?.call('$e'),
      delay: const Duration(milliseconds: 400),
    );
  }

  Node get node => controller.node;

  Future<void> start() async {
    if (_started) return;
    _started = true;
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
    // Notifications from an earlier run outlive the process: treat them as
    // scheduled so a pass cancels any whose event was since changed.
    try {
      for (final pending
          in await notifications.plugin.pendingNotificationRequests()) {
        if (pending.payload?.startsWith('event:') ?? false) {
          _scheduled[pending.id] = '';
        }
      }
    } catch (_) {
      /* Platforms that cannot list pending notifications. */
    }
    controller.addListener(_task.schedule);
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
    _task.schedule();
  }

  /// The reminders due between [from] and [to], soonest first.
  List<DueReminder> due(DateTime from, DateTime to) {
    final calendar = controller.calendar;
    final result = <DueReminder>[];
    // An occurrence that starts after [to] can still have a reminder before
    // it, so look as far past as the longest reminder reaches.
    final occurrences = calendar.between(
      from.subtract(const Duration(days: 1)),
      to.add(const Duration(days: 8)),
      calendars: {
        for (final c in controller.calendars)
          if (calendar.shown(c.id)) c.id,
      },
    );
    for (final o in occurrences) {
      for (final minutes in calendar.remindersFor(o.event)) {
        final at = o.allDay
            ? DateTime(o.start.year, o.start.month, o.start.day, 9)
                  .subtract(Duration(minutes: minutes))
            : o.start.subtract(Duration(minutes: minutes));
        if (at.isBefore(from) || !at.isBefore(to)) continue;
        result.add(DueReminder(o, minutes, at));
      }
    }
    result.sort((a, b) => a.at.compareTo(b.at));
    return result;
  }

  /// Tells this person when someone else adds an event to a group calendar,
  /// or moves one. Works from an insertion cursor kept in settings, so it
  /// costs what arrived and never re-announces history.
  Future<void> _announce() async {
    final calendar = controller.calendar;
    var cursor = node.store.setting(_alertCursor) as int?;
    if (cursor == null) {
      // The first run starts from now: what is already here is not news.
      node.store.set(_alertCursor, node.store.insertionCursor);
      return;
    }
    await calendar.refresh();
    final target = node.store.insertionCursor;
    final recent = DateTime.now().subtract(const Duration(days: 2));
    while (!_closed) {
      final page = node.store.insertedOfKind(cursor!, Calendar.eventKind);
      if (page.isEmpty) break;
      for (final (sequence, o) in page) {
        cursor = sequence;
        if (o.author == node.person ||
            o.isPublic ||
            o.space == Calendar.personal ||
            chatMuted(node, o.space) ||
            DateTime.fromMillisecondsSinceEpoch(o.created).isBefore(recent)) {
          continue;
        }
        final p = await node.content(o);
        if (p == null || p['history'] == true || p['deleted'] == true) continue;
        final entry = p['event'] as String;
        // Only what is shown counts: written by a member, and the latest.
        final e = calendar.event(o.space, entry);
        if (e == null || e.object.id != o.id || e.isOverride) continue;
        final key = 'calAlerted/${o.space}/$entry';
        final start = e.start.millisecondsSinceEpoch;
        final before = node.store.setting(key);
        if (before == start) continue;
        node.store.set(key, start);
        final first = e.repeat == null
            ? e.start
            : calendar
                      .occurrence(o.space, entry, after: DateTime.now())
                      ?.start ??
                  e.start;
        final text = e.allDay
            ? formatDay(first)
            : '${formatDay(first)}, ${_clock(first)}';
        await notifications.plugin.show(
          id: notificationId('alert|${o.space}|$entry', range),
          title: before == null
              ? 'New event · ${controller.nameOf(o.space)}'
              : 'Event moved · ${controller.nameOf(o.space)}',
          body: '${eventTitle(e)} · $text',
          payload: 'event:${Calendar.link(o.space, entry)}',
          notificationDetails: _details,
        );
      }
    }
    node.store.set(_alertCursor, cursor ?? target);
  }

  static const _alertCursor = 'calAlertCursor';

  Future<void> sync() async {
    if (_closed) return;
    try {
      await _announce();
    } catch (e) {
      notifications.onError?.call('$e');
    }
    final now = DateTime.now();
    _upcoming = due(now, now.add(horizon));
    final wanted = <int, DueReminder>{};
    for (final d in _upcoming.take(limit)) {
      wanted[d.id] = d;
    }
    for (final id in _scheduled.keys.toList()) {
      if (!wanted.containsKey(id)) {
        await _cancel(id);
        _scheduled.remove(id);
      }
    }
    for (final entry in wanted.entries) {
      final fingerprint = entry.value.fingerprint(controller);
      if (_scheduled[entry.key] == fingerprint) continue;
      if (await _schedule(entry.value)) _scheduled[entry.key] = fingerprint;
    }
  }

  NotificationDetails get _details => const NotificationDetails(
    android: AndroidNotificationDetails(
      'events',
      'Event reminders',
      channelDescription: 'Reminders for calendar events',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.private,
    ),
    windows: WindowsNotificationDetails(),
  );

  String _body(DueReminder d) {
    final e = d.occurrence.event;
    final when = d.occurrence.allDay
        ? 'All day'
        : '${_clock(d.occurrence.start)} – ${_clock(d.occurrence.end)}';
    return [
      when,
      if (e.location.isNotEmpty) e.location,
      if (d.occurrence.calendar != Calendar.personal)
        controller.nameOf(d.occurrence.calendar),
    ].join(' · ');
  }

  String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _payload(DueReminder d) => 'event:${Calendar.link(
    d.occurrence.calendar,
    d.occurrence.entry,
    key: d.occurrence.repeats ? d.occurrence.key : null,
  )}';

  Future<bool> _schedule(DueReminder d) async {
    if (!_scheduling) return false;
    try {
      await notifications.plugin.zonedSchedule(
        id: d.id,
        title: eventTitle(d.occurrence.event),
        body: _body(d),
        payload: _payload(d),
        scheduledDate: tz.TZDateTime.from(d.at, tz.local),
        notificationDetails: _details,
        androidScheduleMode: _exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
      );
      return true;
    } catch (_) {
      // Unsupported here: fall back to the timer while OurNet runs.
      if (!Platform.isAndroid) _scheduling = false;
      return false;
    }
  }

  Future<void> _cancel(int id) async {
    try {
      await notifications.plugin.cancel(id: id);
    } catch (_) {}
  }

  /// Shows reminders the system could not schedule, and refreshes the list
  /// once an hour so the horizon moves on.
  Future<void> _tick() async {
    if (_closed) return;
    final now = DateTime.now();
    if (now.minute == 0) _task.schedule();
    if (_scheduling) return;
    final window = due(now.subtract(const Duration(minutes: 2)), now.add(const Duration(seconds: 30)));
    for (final d in window) {
      final key = 'calShown/${d.id}';
      final at = d.at.millisecondsSinceEpoch;
      if (node.store.setting(key) == at) continue;
      node.store.set(key, at);
      await notifications.plugin.show(
        id: d.id,
        title: eventTitle(d.occurrence.event),
        body: _body(d),
        payload: _payload(d),
        notificationDetails: _details,
      );
    }
  }

  void close() {
    _closed = true;
    controller.removeListener(_task.schedule);
    _timer?.cancel();
    _task.close();
  }
}

/// One reminder: an occurrence, how long before it, and when that is.
class DueReminder {
  final Occurrence occurrence;
  final int minutes;
  final DateTime at;
  DueReminder(this.occurrence, this.minutes, this.at);

  int get id => notificationId(
    '${occurrence.id}|$minutes',
    CalendarReminders.range,
  );

  /// Changes when anything the notification shows or fires on does.
  String fingerprint(CalendarController c) =>
      '${at.millisecondsSinceEpoch}|${occurrence.event.title}|${occurrence.event.location}|${occurrence.start.millisecondsSinceEpoch}|${occurrence.end.millisecondsSinceEpoch}';
}
