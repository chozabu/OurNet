import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet/ui/conversation_history.dart';
import 'package:ournet/ui/message_text.dart';
import 'package:ournet_core/ournet_core.dart';
import 'features_test.dart' show settled;

Future<(Node, List<Node>)> friends(int count) async {
  final node = Node(await LocalIdentity.create(), Store());
  final others = <Node>[];
  for (var i = 0; i < count; i++) {
    final other = Node(await LocalIdentity.create(label: 'Friend $i'), Store());
    await node.addContact(other.identity.certificate);
    await other.addContact(node.identity.certificate);
    others.add(other);
  }
  return (node, others);
}

Future<SignedObject> say(Node from, Node to, String text) => from.publish(
  'message',
  {'text': text},
  space: '_messages',
  audience: [to.person],
);

void wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// [text] within the open conversation, not the chat list's preview.
Finder inChat(String text) => find.descendant(
  of: find.byType(ConversationHistory),
  matching: find.text(text),
);

/// Lets the batched read receipt and other short timers run.
Future<void> reads(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await settled(tester);
}

void main() {
  test('message text formatting helpers', () {
    expect(MessageText.onlyEmoji('👍'), isTrue);
    expect(MessageText.onlyEmoji('❤️ 😂'), isTrue);
    expect(MessageText.onlyEmoji('👍👍👍👍'), isFalse);
    expect(MessageText.onlyEmoji('ok 👍'), isFalse);
    expect(MessageText.onlyEmoji('123'), isFalse);
    expect(
      MessageText.plain('*bold* and _it_ and ~no~ `x`'),
      'bold and it and no x',
    );
    expect(MessageText.plain('2*3*4 snake_case_name'), '2*3*4 snake_case_name');
    expect(
      MessageText.linkUri('www.example.com')?.toString(),
      'https://www.example.com',
    );
    expect(MessageText.linkUri('javascript:alert(1)'), isNull);
  });

  testWidgets('chats are ordered by latest message and read when shown', (
    tester,
  ) async {
    wide(tester);
    final (node, [quiet, chatty]) = await friends(2);
    await chatty.publish('profile', {'name': 'Chatty'}, space: '_identity');
    await quiet.publish('profile', {'name': 'Quiet'}, space: '_identity');
    await say(node, quiet, 'Old news');
    final incoming = await say(chatty, node, 'Fresh message');
    await tester.runAsync(() => syncPair(node, chatty));
    await tester.runAsync(() => syncPair(node, quiet));
    expect(node.store.conversationUnread(node.person), 1);
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.messages,
      ),
    );
    await settled(tester);
    final tiles = find.byType(ListTile);
    final chattyTile = find.ancestor(of: find.text('Chatty'), matching: tiles);
    final quietTile = find.ancestor(of: find.text('Quiet'), matching: tiles);
    expect(
      tester.getTopLeft(chattyTile.first).dy,
      lessThan(tester.getTopLeft(quietTile.first).dy),
    );
    // The most recent chat opens, and what is on screen is read.
    expect(find.text('Fresh message'), findsWidgets);
    expect(find.text('Unread messages'), findsOneWidget);
    await reads(tester);
    expect(node.store.conversationUnread(node.person), 0);
    await tester.runAsync(() => syncPair(node, chatty));
    expect(chatty.store.setting('readBy/${incoming.id}'), node.person);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await quiet.close();
    await chatty.close();
  });

  testWidgets('reply, react, edit and delete from the message menu', (
    tester,
  ) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    final hello = await say(friend, node, 'Hello from friend');
    await tester.runAsync(() => syncPair(node, friend));
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.messages,
      ),
    );
    await settled(tester);
    await reads(tester);

    // Reply: the quote goes with the message and shows in its bubble.
    await tester.longPress(inChat('Hello from friend'));
    await settled(tester);
    await tester.tap(find.text('Reply'));
    await settled(tester);
    expect(find.byTooltip('Cancel reply'), findsOneWidget);
    final composer = find.byType(TextField).last;
    await tester.enterText(composer, 'Hi back');
    await tester.tap(find.byIcon(Icons.send));
    await settled(tester);
    final mine = node.store
        .conversation(node.person, friend.person)
        .firstWhere((o) => o.author == node.person);
    expect((await node.content(mine))!['reply'], hello.id);
    expect(inChat('Hi back'), findsOneWidget);
    expect(inChat('Hello from friend'), findsNWidgets(2));
    expect(find.byTooltip('Cancel reply'), findsNothing);

    // React with a quick reaction.
    await tester.longPress(inChat('Hello from friend').last);
    await settled(tester);
    await tester.tap(find.text('👍'));
    await settled(tester);
    expect(MessageUpdates(node).reactions(hello), {node.person: '👍'});
    expect(inChat('👍'), findsOneWidget);

    // Edit this person's own message.
    await tester.longPress(inChat('Hi back'));
    await settled(tester);
    await tester.tap(find.text('Edit'));
    await settled(tester);
    expect(tester.widget<TextField>(composer).controller!.text, 'Hi back');
    await tester.enterText(composer, 'Hi again');
    await tester.tap(find.byIcon(Icons.send));
    await settled(tester);
    expect(inChat('Hi again'), findsOneWidget);
    expect(find.textContaining('edited'), findsOneWidget);
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);

    // Delete it for everyone.
    await tester.longPress(inChat('Hi again'));
    await settled(tester);
    await tester.tap(find.text('Delete…'));
    await settled(tester);
    await tester.tap(find.text('Delete for everyone'));
    await settled(tester);
    expect(find.text('You deleted this message'), findsOneWidget);
    await tester.runAsync(() async {
      await syncPair(node, friend);
      await MessageUpdates(friend).catchUp();
    });
    expect(MessageUpdates(friend).deleted(mine), isTrue);
    expect(MessageUpdates(friend).reactions(hello), {node.person: '👍'});
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });

  testWidgets('pinned, muted and archived chats', (tester) async {
    wide(tester);
    final (node, [a, b]) = await friends(2);
    await a.publish('profile', {'name': 'Ann'}, space: '_identity');
    await b.publish('profile', {'name': 'Bob'}, space: '_identity');
    await say(node, a, 'to Ann');
    await say(node, b, 'to Bob');
    await tester.runAsync(() => syncPair(node, a));
    await tester.runAsync(() => syncPair(node, b));
    node.store.set('chatPinned/${a.person}', true);
    node.store.set('chatMuted/${a.person}', true);
    node.store.set(
      'chatArchived/${b.person}',
      DateTime.now().millisecondsSinceEpoch + 1000,
    );
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.messages,
      ),
    );
    await settled(tester);
    expect(find.text('Archived (1)'), findsOneWidget);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(find.byIcon(Icons.volume_off), findsOneWidget);
    await tester.tap(find.text('Archived (1)'));
    await settled(tester);
    expect(find.text('Bob'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await a.close();
    await b.close();
  });
}
