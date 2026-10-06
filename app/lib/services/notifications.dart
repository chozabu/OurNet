import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:ournet_core/ournet_core.dart';
import 'messaging.dart';

/// A stable notification ID for [key] inside [range], a power of two: chats,
/// forums and note reminders each keep to their own range, clear of the call
/// notification (1). FNV-1a.
int notificationId(String key, int range) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return range | (hash & (range - 1));
}

const reminderRange = 0x40000000, _chatRange = 0x20000000;
const _forumRange = 0x10000000, _callId = 1, _groupRange = 0x08000000;

/// Arrivals signed longer ago than this are history catching up (a newly
/// linked device, a friend back after weeks) rather than news.
const _recent = Duration(days: 2);

/// Whether a private group's record is a new chat message, as opposed to an
/// edit, a deletion, a pin, a list item or history copied for a new member.
bool isGroupChatMessage(Json p) =>
    p['type'] != 'pin' &&
    p['type'] != 'check' &&
    p['deleted'] != true &&
    p['edited'] != true &&
    p['history'] != true;

/// What a button on a notification asks for, or null for a plain tap:
/// `read <person>` or `reply <person> <text>`. On Android buttons run without
/// the app's interface, possibly with no app running at all; see
/// background_sync.dart. Windows passes a button's arguments as the payload,
/// to the running app.
List<String>? notificationAction(NotificationResponse response) {
  final payload = response.payload;
  if (payload == null) return null;
  if (payload.startsWith('reply:')) {
    return ['reply', payload.substring(6), '${response.data['message'] ?? ''}'];
  }
  if (payload.startsWith('read:')) return ['read', payload.substring(5)];
  if (payload.startsWith('readgroup:')) {
    return ['readGroup', payload.substring(10)];
  }
  if (payload.startsWith('group:')) {
    return response.actionId == 'read'
        ? ['readGroup', payload.substring(6)]
        : null;
  }
  if (!payload.startsWith('chat:')) return null;
  final peer = payload.substring(5);
  return switch (response.actionId) {
    'reply' => ['reply', peer, response.input ?? ''],
    'read' => ['read', peer],
    _ => null,
  };
}

/// Carries out a [notificationAction] on [node]. Replying marks the chat read.
Future<void> runNotificationAction(Node node, List<String> action) async {
  switch (action) {
    case ['reply', final peer, final text] when text.trim().isNotEmpty:
      await sendMessage(node, peer, text);
      await node.markConversationRead(peer);
    case ['read', final peer]:
      await node.markConversationRead(peer);
    case ['readGroup', final space]:
      await node.markRoomRead(space);
  }
}

/// Operating system notifications for new activity: one per chat, showing
/// its unread messages with reply and mark-read buttons; one quiet summary
/// per forum; incoming calls. Both the app and background sync run one.
class Notifications {
  final Node node;
  final plugin = FlutterLocalNotificationsPlugin();

  /// Handles notification buttons. Must be a top-level entry point.
  final DidReceiveBackgroundNotificationResponseCallback? onAction;

  /// Everything already stored when this started is not new activity. An
  /// insertion cursor says that in one number, where remembering every
  /// stored ID grew with history and missed anything past its read limit.
  int cursor = 0;
  StreamSubscription<void>? subscription;
  bool ready = false;
  void Function(String person)? onOpenChat;
  void Function(String space)? onOpenForum;
  void Function(String space)? onOpenGroup;

  /// Opens the event a reminder was for, by its link.
  void Function(String link)? onOpenEvent;
  void Function(String note)? onOpenNote;

  /// A call notification was tapped ([action] null) or one of its buttons
  /// pressed (`answer` or `decline`).
  void Function(String? action)? onCallOpen;
  void Function(String)? onError;

  /// Called first when a notification is tapped, to bring the app forward.
  void Function()? onTap;

  /// Whether the user is already looking at what a notification with this
  /// payload would open, so it need not be shown.
  bool Function(String payload)? showing;

  /// People whose chat notification is showing.
  final _chats = <String>{};
  Future<void>? _checking;
  bool _dirty = false;

  /// Edits and deletions, so a notification shows what the author meant.
  final MessageUpdates updates;

  Notifications(this.node, {this.onAction, MessageUpdates? updates})
    : updates = updates ?? MessageUpdates(node);
  Future<void>? _initialising;

  /// On by default on Android, where the system manages them per channel,
  /// and on Windows, where OurNet keeps running in the tray to show them.
  bool get enabled =>
      node.store.setting('notifications') as bool? ??
      (Platform.isAndroid || Platform.isWindows);

  /// Whether notifications show what was written, or only who wrote. Chats
  /// are private notifications, so a secure lock screen can hide them too.
  bool get previews => node.store.setting('notificationPreviews') != false;

  /// Safe to call more than once; later calls wait for the first.
  Future<void> initialise() => _initialising ??= _initialise();

  Future<void> _initialise() async {
    cursor = node.store.insertionCursor;
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
      onDidReceiveNotificationResponse: _open,
      onDidReceiveBackgroundNotificationResponse: onAction,
    );
    ready = true;
    // Replaced by per-chat and per-forum channels, and by a call channel
    // that vibrates (a channel's sound and vibration cannot be changed).
    for (final old in ['activity', 'calls']) {
      unawaited(
        plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.deleteNotificationChannel(channelId: old)
            .catchError((Object _) {}),
      );
    }
    try {
      // Chats shown by an earlier run or by background sync.
      for (final active in await plugin.getActiveNotifications()) {
        final payload = active.payload;
        if (payload != null && payload.startsWith('chat:')) {
          _chats.add(payload.substring(5));
        }
      }
    } catch (_) {
      /* Platforms that cannot list shown notifications. */
    }
    subscription = node.changes.stream.listen((_) => _schedule());
    try {
      final launch = await plugin.getNotificationAppLaunchDetails();
      final response = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && response != null) {
        _open(response);
      }
    } catch (_) {
      /* Platforms without launch details. */
    }
  }

  void _open(NotificationResponse response) {
    final action = notificationAction(response);
    if (action != null) {
      unawaited(
        runNotificationAction(
          node,
          action,
        ).catchError((Object e) => onError?.call('$e')),
      );
      return;
    }
    onTap?.call();
    final payload = response.payload ?? '';
    final split = payload.indexOf(':');
    final key = payload.substring(split + 1);
    switch (split < 0 ? payload : payload.substring(0, split)) {
      case 'chat':
        onOpenChat?.call(key);
      case 'forum':
        onOpenForum?.call(key);
      case 'group':
        onOpenGroup?.call(key);
      case 'note':
        onOpenNote?.call(key);
      case 'event':
        onOpenEvent?.call(key);
      case 'call':
        onCallOpen?.call(response.actionId);
    }
  }

  /// Asks the system to allow notifications. False when refused.
  Future<bool> requestPermission() async {
    if (!ready) await initialise();
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? false;
    }
    return await plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, sound: true, badge: true) ??
        true;
  }

  /// Asks once, the first time the app runs with notifications on by
  /// default. Later changes go through [setEnabled].
  Future<void> requestPermissionOnce() async {
    if (!enabled || node.store.setting('notificationsAsked') == true) return;
    node.store.set('notificationsAsked', true);
    await requestPermission();
  }

  Future<void> setEnabled(bool value) async {
    if (value) await requestPermission();
    node.store.set('notifications', value);
    if (!value) {
      for (final peer in _chats.toList()) {
        await dismiss('chat:$peer');
      }
    }
  }

  /// At most one check runs; changes during it run it once more.
  void _schedule() {
    _dirty = true;
    _checking ??= () async {
      while (_dirty) {
        _dirty = false;
        try {
          await check();
        } catch (e) {
          onError?.call('$e');
        }
      }
      _checking = null;
    }();
  }

  Future<void> check() async {
    // Arrival order, not signed wall clocks: a burst of synced history cannot
    // push a genuinely new message out of view, and a sender cannot promote
    // one by dating it forward.
    const page = 128;
    final target = node.store.insertionCursor;
    final recent = DateTime.now().subtract(_recent).millisecondsSinceEpoch;
    final chats = <String>{};
    final forums = <String, List<SignedObject>>{};
    final groups = <String, List<(SignedObject, Json)>>{};
    final readElsewhere = <String>{};
    while (true) {
      final arrived = node.store.insertedAfter(cursor, [
        'message',
        'post',
        'room_item',
        'room_read',
      ], limit: page);
      for (final (sequence, o) in arrived) {
        cursor = sequence;
        if (o.kind == 'room_read') {
          // Read on another device: what it covered is no longer news.
          if (o.author != node.person) continue;
          final read = await node.content(o);
          final space = read?['space'], upTo = read?['upTo'];
          if (space is! String || upTo is! int) continue;
          groups[space]?.removeWhere((g) => g.$1.created <= upTo);
          readElsewhere.add(space);
          continue;
        }
        if (o.author == node.person || !node.visible(o) || o.created < recent) {
          continue;
        }
        if (o.kind == 'message') {
          if (!chatMuted(node, o.author)) chats.add(o.author);
        } else if (o.kind == 'room_item') {
          if (!enabled || chatMuted(node, o.space) || o.isPublic) continue;
          final payload = await node.content(o);
          if (payload != null && isGroupChatMessage(payload)) {
            (groups[o.space] ??= []).add((o, payload));
          }
        } else if (node.subscriptions.contains(o.space)) {
          (forums[o.space] ??= []).add(o);
        }
      }
      // A short page means the scan reached the end, so the cursor moves
      // past everything it walked rather than past the last match. Looking
      // for a kind walks the rows in between, and a profile with no messages
      // at all would otherwise rescan it on every change.
      if (arrived.length < page) break;
    }
    if (cursor < target) cursor = target;
    for (final space in readElsewhere) {
      await dismiss('group:$space');
    }
    if (enabled) {
      for (final peer in chats) {
        if (showing?.call('chat:$peer') != true) await _showChat(peer);
      }
      if (groups.isNotEmpty) {
        final names = {
          for (final room in await Everyday(node).rooms())
            if (room.data['note'] != true)
              room.object.space: '${room.data['name']}',
        };
        for (final MapEntry(key: space, value: items) in groups.entries) {
          final name = names[space];
          if (name != null &&
              items.isNotEmpty &&
              showing?.call('group:$space') != true) {
            await _showGroup(space, name, items);
          }
        }
      }
      for (final MapEntry(key: space, value: posts) in forums.entries) {
        if (showing?.call('forum:$space') != true) {
          await _showForum(space, posts);
        }
      }
    }
    // Read here, on another device or from a notification button.
    for (final peer in _chats.toList()) {
      if (node.store.conversationUnread(node.person, peer: peer) == 0) {
        await dismiss('chat:$peer');
      }
    }
  }

  Future<void> _showChat(String peer) async {
    await updates.catchUp();
    final unread = <SignedObject>[];
    final texts = <String>[];
    for (final o
        in node.store
            .unreadMessages(node.person, peer, limit: 6)
            .where(node.visible)
            .toList()
            .reversed) {
      if (updates.hidden(o)) continue;
      final payload = await node.content(o);
      final current = payload == null ? null : updates.current(o, payload);
      if (payload != null && current == null) continue;
      // A call they took or declined is history, not news.
      if (quietCallEntry(current)) {
        await node.markRead(o.id);
        continue;
      }
      unread.add(o);
      texts.add(_orNew(contentPreview(current)));
    }
    if (unread.isEmpty) return;
    final count = node.store.conversationUnread(node.person, peer: peer);
    final name = profileName(node, peer) ?? 'A friend';
    final avatar = node.avatars.of(peer)?.bytes;
    final sender = Person(
      key: peer,
      name: name,
      icon: avatar == null ? null : ByteArrayAndroidIcon(avatar),
    );
    final messages = [
      if (previews)
        for (var i = 0; i < unread.length; i++)
          Message(
            texts[i],
            DateTime.fromMillisecondsSinceEpoch(unread[i].created),
            sender,
          ),
    ];
    await plugin.show(
      id: notificationId(peer, _chatRange),
      title: name,
      body: previews
          ? messages.last.text
          : count == 1
          ? 'New message'
          : '$count new messages',
      payload: 'chat:$peer',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          'Messages',
          channelDescription: 'Private messages from friends',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.private,
          number: count,
          largeIcon: avatar == null ? null : ByteArrayAndroidBitmap(avatar),
          styleInformation: previews
              ? MessagingStyleInformation(
                  Person(key: node.person, name: 'You'),
                  messages: messages,
                )
              : null,
          actions: const [
            AndroidNotificationAction(
              'reply',
              'Reply',
              inputs: [AndroidNotificationActionInput(label: 'Message')],
            ),
            AndroidNotificationAction('read', 'Mark read'),
          ],
        ),
        windows: WindowsNotificationDetails(
          timestamp: DateTime.fromMillisecondsSinceEpoch(unread.last.created),
          subtitle: previews && count > 1 ? '$count unread' : null,
          inputs: const [
            WindowsTextInput(id: 'message', placeHolderContent: 'Reply'),
          ],
          actions: [
            WindowsAction(
              content: 'Send',
              arguments: 'reply:$peer',
              inputId: 'message',
            ),
            WindowsAction(content: 'Mark read', arguments: 'read:$peer'),
          ],
        ),
      ),
    );
    _chats.add(peer);
  }

  /// One notification per private group, counting messages since the group
  /// was last opened. A burst replaces it rather than stacking.
  Future<void> _showGroup(
    String space,
    String group,
    List<(SignedObject, Json)> items,
  ) async {
    final key = 'groupAlerts/$space';
    final count = (node.store.setting(key) as int? ?? 0) + items.length;
    node.store.set(key, count);
    final (latest, payload) = items.reduce(
      (a, b) => b.$1.created >= a.$1.created ? b : a,
    );
    final author = profileName(node, latest.author) ?? 'A member';
    final line = previews
        ? '$author: ${_orNew(contentPreview(payload))}'
        : 'New message from $author';
    await plugin.show(
      id: notificationId(space, _groupRange),
      title: group,
      body: count == 1 ? line : '$count new messages · $line',
      payload: 'group:$space',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          'Messages',
          channelDescription: 'Private messages from friends',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.private,
          number: count,
          actions: const [AndroidNotificationAction('read', 'Mark read')],
        ),
        windows: WindowsNotificationDetails(
          timestamp: DateTime.fromMillisecondsSinceEpoch(latest.created),
          actions: [
            WindowsAction(content: 'Mark read', arguments: 'readgroup:$space'),
          ],
        ),
      ),
    );
  }

  /// One notification per forum, counting posts since the forum was last
  /// opened. It sounds once while shown, and only for replies to this person.
  Future<void> _showForum(String space, List<SignedObject> posts) async {
    final key = 'postAlerts/$space';
    final count = (node.store.setting(key) as int? ?? 0) + posts.length;
    node.store.set(key, count);
    SignedObject? reply;
    for (final post in posts) {
      final parent = (await node.content(post))?['parent'];
      if (parent is String && node.store.get(parent)?.author == node.person) {
        reply = post;
      }
    }
    final latest = reply ?? posts.last;
    final author = profileName(node, latest.author) ?? 'Someone';
    final text = previews
        ? _orNew(contentPreview(await node.content(latest)))
        : '';
    final line = reply != null
        ? '$author replied to you${previews ? ': $text' : ''}'
        : previews
        ? '$author: $text'
        : 'New post by $author';
    await plugin.show(
      id: notificationId(space, _forumRange),
      title: _forumName(space),
      body: count == 1 ? line : '$count new posts · $line',
      payload: 'forum:$space',
      notificationDetails: NotificationDetails(
        android: reply != null
            ? AndroidNotificationDetails(
                'replies',
                'Replies to you',
                channelDescription: 'Forum replies to your posts',
                category: AndroidNotificationCategory.social,
                onlyAlertOnce: true,
                number: count,
              )
            : AndroidNotificationDetails(
                'forums',
                'Forum activity',
                channelDescription: 'New posts in forums you joined',
                importance: Importance.low,
                priority: Priority.low,
                category: AndroidNotificationCategory.social,
                onlyAlertOnce: true,
                number: count,
              ),
        // Replacing a toast shows it again; only replies make a sound.
        windows: WindowsNotificationDetails(
          audio: reply != null ? null : WindowsNotificationAudio.silent(),
        ),
      ),
    );
  }

  String _orNew(String text) => text.isEmpty ? 'New message' : text;

  String _forumName(String space) {
    for (final o in node.store.objects(
      kind: 'forum',
      space: space,
      limit: 16,
    )) {
      if (isForumDefinition(node, o) && o.data['payload']['name'] is String) {
        return o.data['payload']['name'] as String;
      }
    }
    return 'Forum';
  }

  /// Removes the notification for [payload] (`chat:<person>` or
  /// `forum:<space>`), when it has been read or opened in the app.
  Future<void> dismiss(String payload) async {
    if (!ready) return;
    if (payload.startsWith('chat:')) {
      final peer = payload.substring(5);
      if (!_chats.remove(peer)) return;
      await plugin.cancel(id: notificationId(peer, _chatRange));
    } else if (payload.startsWith('group:')) {
      final space = payload.substring(6);
      node.store.set('groupAlerts/$space', null);
      await plugin.cancel(id: notificationId(space, _groupRange));
    } else if (payload.startsWith('forum:')) {
      final space = payload.substring(6);
      final key = 'postAlerts/$space';
      if (node.store.setting(key) == null) return;
      node.store.set(key, null);
      await plugin.cancel(id: notificationId(space, _forumRange));
    }
  }

  /// Stops watching, after any check in progress so that nothing stored
  /// before now goes unannounced.
  Future<void> close() async {
    await subscription?.cancel();
    await _checking;
  }

  /// Shows an incoming call with Answer and Decline buttons. The app plays
  /// the ringtone itself (see `Ringer`); on Android this vibrates until the
  /// call is answered or ends.
  Future<void> incomingCall(String? caller, {bool video = false}) async {
    if (!ready || !enabled) return;
    final kind = video ? 'video call' : 'call';
    final avatar = caller == null ? null : node.avatars.of(caller)?.bytes;
    await plugin.show(
      id: _callId,
      title: caller == null
          ? 'Incoming OurNet $kind'
          : 'Incoming $kind from ${profileName(node, caller) ?? 'a friend'}',
      body: 'Tap to open, or answer here.',
      payload: 'call',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'incoming_calls',
          'Incoming calls',
          channelDescription: 'Vibrates while a friend is calling',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          largeIcon: avatar == null ? null : ByteArrayAndroidBitmap(avatar),
          // Takes over the screen when it is off or locked (see CallScreen).
          fullScreenIntent: true,
          playSound: false,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 900, 700, 900, 1500]),
          // FLAG_INSISTENT: repeat the vibration until cancelled.
          additionalFlags: Int32List.fromList([4]),
          ongoing: true,
          autoCancel: false,
          timeoutAfter: 70000,
          actions: const [
            AndroidNotificationAction(
              'decline',
              'Decline',
              showsUserInterface: true,
              cancelNotification: true,
            ),
            AndroidNotificationAction(
              'answer',
              'Answer',
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ],
        ),
        windows: const WindowsNotificationDetails(),
      ),
    );
  }

  Future<void> clearCall() async {
    if (ready) await plugin.cancel(id: _callId);
  }
}
