import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/notifications.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  late List<MethodCall> calls;
  late Node a, b;
  late Notifications notifications;

  setUp(() async {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'initialize' => true,
            'getActiveNotifications' => <Object?>[],
            _ => null,
          };
        });
    a = Node(await LocalIdentity.create(), Store());
    b = Node(await LocalIdentity.create(), Store());
    await a.addContact(b.identity.certificate);
    await b.addContact(a.identity.certificate);
    await b.publish('profile', {'name': 'Bea'}, space: '_identity');
    await syncPair(a, b);
    a.store.set('notifications', true);
    notifications = Notifications(a);
    await notifications.initialise();
  });

  tearDown(() async {
    await notifications.close();
    await a.close();
    await b.close();
  });

  List<Map<Object?, Object?>> shown() => [
    for (final call in calls)
      if (call.method == 'show') call.arguments as Map<Object?, Object?>,
  ];

  Future<void> settle() async {
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> message(String text) => b.publish(
    'message',
    {'text': text},
    space: '_messages',
    audience: [a.person],
  );

  test('a burst of messages shows one chat notification per friend', () async {
    await message('Hello');
    await message('Are you there?');
    await syncPair(a, b);
    await settle();
    final chat = shown().single;
    expect(chat['title'], 'Bea');
    expect(chat['body'], 'Are you there?');
    expect(chat['payload'], 'chat:${b.person}');
    final details = chat['platformSpecifics'] as Map<Object?, Object?>;
    expect(details['channelId'], 'messages');
    final style = details['styleInformation'] as Map<Object?, Object?>;
    expect(
      [for (final m in style['messages'] as List) (m as Map)['text']],
      ['Hello', 'Are you there?'],
    );
    expect(
      [for (final action in details['actions'] as List) (action as Map)['id']],
      ['reply', 'read'],
    );

    // Reading the chat, here or on another device, clears it.
    calls.clear();
    await a.markConversationRead(b.person);
    await settle();
    expect(calls.map((c) => c.method), contains('cancel'));
  });

  test('nothing is shown for the chat on screen or without previews', () async {
    notifications.showing = (payload) => payload == 'chat:${b.person}';
    await message('Seen already');
    await syncPair(a, b);
    await settle();
    expect(shown(), isEmpty);

    notifications.showing = null;
    a.store.set('notificationPreviews', false);
    await message('Secret');
    await syncPair(a, b);
    await settle();
    final chat = shown().single;
    expect(chat['title'], 'Bea');
    expect(chat['body'], '2 new messages');
    final details = chat['platformSpecifics'] as Map<Object?, Object?>;
    expect(details['style'], AndroidNotificationStyle.defaultStyle.index);
  });

  test('a reply button sends the reply and marks the chat read', () async {
    await message('Lunch?');
    await syncPair(a, b);
    final action = notificationAction(
      NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: 'reply',
        input: 'Yes!',
        payload: 'chat:${b.person}',
      ),
    );
    expect(action, ['reply', b.person, 'Yes!']);
    await runNotificationAction(a, action!);
    expect(a.store.conversationUnread(a.person, peer: b.person), 0);
    await syncPair(a, b);
    final replies = b.store.unreadMessages(b.person, a.person);
    expect((await b.content(replies.single))!['text'], 'Yes!');
  });

  test('Windows buttons carry their action in the payload', () {
    NotificationResponse button(String arguments, [String? text]) =>
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: arguments,
          actionId: arguments,
          data: {'message': ?text},
        );
    expect(notificationAction(button('reply:${b.person}', 'Yes!')), [
      'reply',
      b.person,
      'Yes!',
    ]);
    expect(notificationAction(button('read:${b.person}')), ['read', b.person]);
    // The toast itself opens the chat.
    expect(notificationAction(button('chat:${b.person}')), isNull);
  });

  test('forum replies to you alert; other posts are a quiet summary', () async {
    final mine = await a.publish('post', {'text': 'Question'});
    await syncPair(a, b);
    await b.publish('post', {'text': 'Unrelated'});
    await syncPair(a, b);
    await settle();
    final quiet = shown().single;
    expect(quiet['payload'], 'forum:general');
    expect(
      (quiet['platformSpecifics'] as Map<Object?, Object?>)['channelId'],
      'forums',
    );

    calls.clear();
    await b.publish('post', {'text': 'Answer', 'parent': mine.id});
    await syncPair(a, b);
    await settle();
    final reply = shown().single;
    expect(reply['id'], quiet['id']);
    expect(reply['body'], '2 new posts · Bea replied to you: Answer');
    expect(
      (reply['platformSpecifics'] as Map<Object?, Object?>)['channelId'],
      'replies',
    );

    // Opening the forum starts the count again.
    await notifications.dismiss('forum:general');
    expect(a.store.setting('postAlerts/general'), isNull);
  });
}
