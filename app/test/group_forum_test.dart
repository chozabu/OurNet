import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';
import 'chat_features_test.dart' show friends, wide;
import 'features_test.dart' show settled;

/// Like [settled] but for screens with a focused text field, whose blinking
/// cursor keeps pumpAndSettle from ever finishing.
Future<void> steady(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  testWidgets('a group has its own private forum', (tester) async {
    wide(tester);
    tester.view.physicalSize = const Size(1200, 1500);
    final (node, [friend]) = await friends(1);
    await friend.publish('profile', {'name': 'Chatty'}, space: '_identity');
    final room = (await tester.runAsync(
      () => Everyday(node).createRoom('Weekend trip', [friend.person]),
    ))!;
    await tester.runAsync(() => syncPair(node, friend));
    final theirs = (await tester.runAsync(
      () => Everyday(friend).rooms(),
    ))!.single;
    await tester.runAsync(
      () => RoomForum(
        friend,
        theirs,
      ).publish({'title': 'Which campsite?', 'text': 'Lake or forest?'}),
    );
    await tester.runAsync(() => syncPair(node, friend));
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.groups,
      ),
    );
    await settled(tester);
    await tester.tap(find.text('Weekend trip'));
    await settled(tester);

    // The tab shows how much is unread, and the discussion with its author.
    expect(find.byType(Badge), findsWidgets);
    await tester.tap(find.text('Forum'));
    await settled(tester);
    expect(find.text('Which campsite?'), findsOneWidget);
    expect(find.text('Lake or forest?'), findsOneWidget);
    expect(find.text('Chatty'), findsOneWidget);
    expect(find.textContaining('Encrypted · group members'), findsOneWidget);

    // Start a discussion of our own.
    await tester.tap(find.text('New discussion'));
    await steady(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Discussion title'),
      'Food',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'What would you like to discuss?'),
      'Who is cooking?',
    );
    await tester.tap(find.text('Publish discussion'));
    await steady(tester);
    expect(find.text('Food'), findsOneWidget);

    // Open the friend's discussion and reply.
    final open = find.textContaining('Open discussion').last;
    await tester.ensureVisible(open);
    await tester.tap(open);
    await steady(tester);
    expect(find.byTooltip('All discussions'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Lake, please');
    await tester.tap(find.text('Comment'));
    await steady(tester);
    expect(find.text('Lake, please'), findsOneWidget);

    // Replies are compact rows; folding one hides its text and counts what
    // sits beneath it, and unfolding brings it back.
    expect(find.text('Reply'), findsWidgets);
    expect(find.byIcon(Icons.remove_circle_outline), findsOneWidget);
    await tester.tap(find.byIcon(Icons.remove_circle_outline));
    await steady(tester);
    expect(find.text('Lake, please'), findsNothing);
    expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await steady(tester);
    expect(find.text('Lake, please'), findsOneWidget);

    // Replying to a reply opens the box under it; Cancel returns it to the top.
    expect(find.text('Cancel'), findsNothing);
    await tester.tap(find.text('Reply').last);
    await steady(tester);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await steady(tester);
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Comment'), findsOneWidget);

    // Everything reaches the friend, who can read the thread; it never
    // appears in the public forum list.
    await tester.runAsync(() => syncPair(node, friend));
    final forum = RoomForum(friend, theirs);
    await tester.runAsync(forum.load);
    expect(forum.topics.length, 2);
    final topic = forum.topics.firstWhere(
      (p) => p.data['title'] == 'Which campsite?',
    );
    expect(forum.thread(topic.object.id).length, 2);
    expect(node.store.objects(kind: 'post'), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
    expect(room, isNotNull);
  });
}
