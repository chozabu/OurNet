import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:ournet_core/ournet_core.dart';

class Notifications {
  final Node node;
  final plugin = FlutterLocalNotificationsPlugin();

  /// Everything already stored when this started is not new activity. An
  /// insertion cursor says that in one number, where remembering every
  /// stored ID grew with history and missed anything past its read limit.
  int cursor = 0;
  StreamSubscription<void>? subscription;
  bool enabled = false, ready = false;
  void Function(String)? onOpen;

  /// A reminder notification for a note was opened.
  void Function(String note)? onOpenNote;
  void Function()? onCallOpen;
  void Function(String)? onError;
  Notifications(this.node);
  Future<void>? _initialising;

  /// Safe to call more than once; later calls wait for the first.
  Future<void> initialise() => _initialising ??= _initialise();

  Future<void> _initialise() async {
    cursor = node.store.insertionCursor;
    enabled = node.store.setting('notifications') == true;
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        windows: WindowsInitializationSettings(
          appName: 'OurNet',
          appUserModelId: 'OurNet.App',
          guid: 'c8e1c95a-479c-4b2b-a99e-bb981344aa82',
        ),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        if (response.payload == '_call') {
          onCallOpen?.call();
          return;
        }
        final payload = response.payload;
        if (payload != null && payload.startsWith('note:')) {
          onOpenNote?.call(payload.substring(5));
        } else if (payload != null) {
          onOpen?.call(payload);
        }
      },
    );
    ready = true;
    subscription = node.changes.stream.listen(
      (_) => unawaited(check().catchError((Object e) => onError?.call('$e'))),
    );
  }

  Future<void> setEnabled(bool value) async {
    if (!ready) await initialise();
    if (value) {
      await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      await plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, sound: true, badge: true);
    }
    enabled = value;
    node.store.set('notifications', value);
  }

  Future<void> check() async {
    // Arrival order, not signed wall clocks: a burst of synced history cannot
    // push a genuinely new message out of view, and a sender cannot promote
    // one by dating it forward.
    const page = 128;
    final target = node.store.insertionCursor;
    final arrived = node.store.insertedAfter(cursor, [
      'message',
      'post',
    ], limit: page);
    for (final (sequence, o) in arrived) {
      cursor = sequence;
      if (!enabled || o.author == node.person || !node.visible(o)) continue;
      await plugin.show(
        id: int.parse(o.id.substring(0, 7), radix: 16),
        title: o.kind == 'message' ? 'New private message' : 'New forum post',
        body: o.kind == 'message'
            ? 'Open OurNet to read it.'
            : 'New activity in ${o.space}',
        payload: o.id,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'activity',
            'Activity',
            importance: Importance.high,
            priority: Priority.high,
          ),
          windows: WindowsNotificationDetails(),
        ),
      );
    }
    // A short page means the scan reached the end without finding more, so
    // the cursor moves past everything it walked rather than past the last
    // match. Looking for a kind walks the rows in between, and a profile with
    // no messages at all would otherwise rescan it on every change.
    if (arrived.length < page && cursor < target) cursor = target;
  }

  Future<void> close() async {
    await subscription?.cancel();
  }

  Future<void> incomingCall() async {
    if (!ready || !enabled) return;
    await plugin.show(
      id: 1,
      title: 'Incoming OurNet call',
      body: 'Open OurNet to answer or decline.',
      payload: '_call',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'calls',
          'Incoming calls',
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.call,
        ),
        windows: WindowsNotificationDetails(),
      ),
    );
  }

  Future<void> clearCall() async {
    if (ready) await plugin.cancel(id: 1);
  }
}
