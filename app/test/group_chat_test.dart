import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet/ui/conversation_history.dart';
import 'package:ournet_core/ournet_core.dart';
import 'chat_features_test.dart' show friends, say, wide;
import 'features_test.dart' show settled;

Finder inChat(String text) => find.descendant(
  of: find.byType(ConversationHistory),
  matching: find.text(text),
);

void main() {
  testWidgets('group chat shows who wrote each message', (tester) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    await friend.publish('profile', {'name': 'Chatty'}, space: '_identity');
    final room = await tester.runAsync(
      () => Everyday(node).createRoom('Weekend trip', [friend.person]),
    );
    await tester.runAsync(() => syncPair(node, friend));
    await tester.runAsync(
      () => Everyday(
        friend,
      ).write({'type': 'note', 'text': 'Who has the tent?'}, room: room!),
    );
    await tester.runAsync(
      () => Everyday(node).write({'type': 'note', 'text': 'I do'}, room: room!),
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
    expect(inChat('Who has the tent?'), findsOneWidget);
    expect(inChat('I do'), findsOneWidget);
    expect(inChat('Chatty'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });

  testWidgets('direct messages show names unless switched off', (tester) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    await friend.publish('profile', {'name': 'Chatty'}, space: '_identity');
    await say(friend, node, 'Hello there');
    await tester.runAsync(() => syncPair(node, friend));
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.messages,
      ),
    );
    await settled(tester);
    expect(inChat('Hello there'), findsOneWidget);
    expect(inChat('Chatty'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    node.store.set('chatNames', false);
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.messages,
      ),
    );
    await settled(tester);
    expect(inChat('Hello there'), findsOneWidget);
    expect(inChat('Chatty'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });

  testWidgets('group composer: Enter sends, Shift+Enter adds a line', (
    tester,
  ) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    await tester.runAsync(
      () => Everyday(node).createRoom('Weekend trip', [friend.person]),
    );
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
    final composer = find.byType(TextField).last;
    final controller = tester.widget<TextField>(composer).controller!;
    await tester.tap(composer);
    await tester.enterText(composer, 'first');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(controller.text, 'first\n');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settled(tester);
    expect(inChat('first'), findsOneWidget);
    expect(controller.text, isEmpty);

    // Send by button keeps the caret in the box.
    await tester.enterText(composer, 'second');
    await tester.tap(find.byIcon(Icons.send));
    await settled(tester);
    expect(inChat('second'), findsOneWidget);
    expect(tester.widget<TextField>(composer).focusNode!.hasFocus, isTrue);

    // Up arrow edits the latest message; Esc leaves edit mode.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await settled(tester);
    expect(controller.text, 'second');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settled(tester);
    expect(controller.text, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });

  testWidgets('reply, react, edit and remove in a group chat', (tester) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    await friend.publish('profile', {'name': 'Chatty'}, space: '_identity');
    final room = await tester.runAsync(
      () => Everyday(node).createRoom('Weekend trip', [friend.person]),
    );
    await tester.runAsync(() => syncPair(node, friend));
    final theirs = (await tester.runAsync(
      () => Everyday(friend).rooms(),
    ))!.single;
    await tester.runAsync(
      () => Everyday(friend).write({
        'type': 'note',
        'text': 'Who has the tent?',
        'sent': DateTime.now().millisecondsSinceEpoch - 1000,
      }, room: theirs),
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

    // Reply: the quote shows in the new bubble and travels with it.
    await tester.longPress(inChat('Who has the tent?'));
    await settled(tester);
    await tester.tap(find.text('Reply'));
    await settled(tester);
    expect(find.byTooltip('Cancel reply'), findsOneWidget);
    final composer = find.byType(TextField).last;
    await tester.enterText(composer, 'I do');
    await tester.tap(find.byIcon(Icons.send));
    await settled(tester);
    expect(inChat('I do'), findsOneWidget);
    expect(inChat('Who has the tent?'), findsNWidgets(2));
    expect(find.byTooltip('Cancel reply'), findsNothing);
    final sent = (await tester.runAsync(
      () => Everyday(node).items(room!),
    ))!.firstWhere((i) => i.data['text'] == 'I do');
    final question = (await tester.runAsync(
      () => Everyday(node).items(room!),
    ))!.firstWhere((i) => i.data['text'] == 'Who has the tent?');
    expect(sent.data['reply'], question.data['entry']);

    // React with a quick reaction; it is filed under the entry.
    await tester.longPress(inChat('Who has the tent?').last);
    await settled(tester);
    await tester.tap(find.text('👍'));
    await settled(tester);
    expect(
      MessageUpdates(
        node,
      ).reactionsFor(Everyday.reactionTarget(question), {node.person}),
      {node.person: '👍'},
    );
    expect(inChat('👍'), findsOneWidget);
    await tester.runAsync(() async {
      await syncPair(node, friend);
      await MessageUpdates(friend).catchUp();
    });
    expect(
      MessageUpdates(
        friend,
      ).reactionsFor(Everyday.reactionTarget(question), {node.person}),
      {node.person: '👍'},
    );

    // Edit this person's own message.
    await tester.longPress(inChat('I do'));
    await settled(tester);
    await tester.tap(find.text('Edit'));
    await settled(tester);
    expect(tester.widget<TextField>(composer).controller!.text, 'I do');
    await tester.enterText(composer, 'I do, in the car');
    await tester.tap(find.byIcon(Icons.send));
    await settled(tester);
    expect(inChat('I do, in the car'), findsOneWidget);
    expect(inChat('I do'), findsNothing);
    expect(find.textContaining('edited'), findsOneWidget);
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);

    // Others' messages cannot be edited or removed from here.
    await tester.longPress(inChat('Who has the tent?').last);
    await settled(tester);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Remove'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await settled(tester);

    // Remove it.
    await tester.longPress(inChat('I do, in the car'));
    await settled(tester);
    await tester.tap(find.text('Remove'));
    await settled(tester);
    expect(inChat('I do, in the car'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });

  testWidgets('message info shows when a group message was sent', (
    tester,
  ) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    await friend.publish('profile', {'name': 'Chatty'}, space: '_identity');
    final room = (await tester.runAsync(
      () => Everyday(node).createRoom('Weekend trip', [friend.person]),
    ))!;
    final sent = DateTime(2026, 10, 1, 19, 24, 1).millisecondsSinceEpoch;
    await tester.runAsync(() async {
      await Everyday(
        node,
      ).write({'type': 'note', 'text': 'Timed', 'sent': sent}, room: room);
      // As written by builds before group entries carried `sent`.
      await node.publish(
        'room_item',
        {
          'type': 'note',
          'text': 'Untimed',
          'entry': 'untimed',
          'clock': 100,
          'epoch': Everyday(node).epoch(room),
          'history': false,
        },
        space: room.object.space,
        audience: await Everyday(node).members(room),
      );
    });
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

    await tester.longPress(inChat('Timed'));
    await settled(tester);
    await tester.tap(find.text('Message info'));
    await settled(tester);
    expect(find.text('Thu 1 Oct 2026, 19:24:01'), findsOneWidget);
    expect(find.text('Not recorded'), findsNothing);
    await tester.tap(find.text('Close'));
    await settled(tester);

    await tester.longPress(inChat('Untimed'));
    await settled(tester);
    await tester.tap(find.text('Message info'));
    await settled(tester);
    expect(find.text('Not recorded'), findsOneWidget);
    expect(find.text('Written'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await settled(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });

  testWidgets('a long group chat opens on the newest and pages back', (
    tester,
  ) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    final room = (await tester.runAsync(
      () => Everyday(node).createRoom('Busy', [friend.person]),
    ))!;
    final base = DateTime.now().millisecondsSinceEpoch - 1000000;
    await tester.runAsync(() async {
      for (var i = 0; i < 300; i++) {
        await Everyday(node).write({
          'type': 'note',
          'text': 'message $i',
          'sent': base + i,
        }, room: room);
      }
    });
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.groups,
      ),
    );
    await settled(tester);
    await tester.tap(find.text('Busy'));
    await settled(tester);
    expect(inChat('message 299'), findsOneWidget);
    // Only a window was read, not the whole group.
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ConversationHistory),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    // Dragging back reads earlier messages as needed.
    for (var i = 0; i < 60 && inChat('message 0').evaluate().isEmpty; i++) {
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await settled(tester);
    }
    expect(inChat('message 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });
}
