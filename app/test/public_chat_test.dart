import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/messaging.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';
import 'chat_features_test.dart' show friends, wide;
import 'features_test.dart' show settled;
import 'scope_helpers.dart';

void main() {
  testWidgets('a public chat is started by name, talked in, and listed in '
      'Public and All', (tester) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.messages,
      ),
    );
    await settled(tester);
    await pickScope(tester, 'Public');
    expect(find.text('No public chats yet'), findsOneWidget);

    await tester.tap(find.text('Start or join a public chat'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, 'Night owls');
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, 'For late talkers');
    await tester.tap(find.text('Save'));
    await settled(tester);
    final space = PublicChats(node, NoteState(node)).joined.single;
    // Called by name: the name is the address.
    expect(space, 'chat:night-owls');
    expect(find.text('night-owls'), findsWidgets);
    expect(find.text('For late talkers'), findsOneWidget);
    expect(find.text('Say hello'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'Anyone up?');
    await tester.tap(find.byIcon(Icons.send));
    await settled(tester);
    expect(find.text('Anyone up?'), findsWidgets);
    expect(
      PublicChats(node, NoteState(node)).latest(space).single.text,
      'Anyone up?',
    );

    // A friend who joins by address writes back.
    await tester.runAsync(() async {
      final theirs = PublicChats(friend, NoteState(friend));
      await theirs.join(space);
      await syncPair(node, friend);
      await theirs.send(space, 'I am', name: 'Owl');
      await syncPair(node, friend);
    });
    await pickScope(tester, 'All');
    await settled(tester);
    // Listed among conversations, and not as a forum.
    expect(find.textContaining('I am'), findsWidgets);
    await openSection(tester, 'Forums');
    await settled(tester);
    expect(find.text('night-owls'), findsNothing);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });

  testWidgets('a chat link in a message joins and opens the chat', (
    tester,
  ) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    late String space;
    await tester.runAsync(() async {
      final theirs = PublicChats(friend, NoteState(friend));
      space = await theirs.create('Board games');
      await theirs.send(space, 'Catan tonight?');
      await sendMessage(
        friend,
        node.person,
        'Come along: ${PublicChats.link(space, name: 'Board games')}',
      );
      await syncPair(node, friend);
    });
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.messages,
      ),
    );
    await settled(tester);
    await tester.tap(find.byType(CircleAvatar).first);
    await settled(tester);
    expect(find.text('Board games'), findsOneWidget);
    await tester.tap(find.text('Join'));
    await settled(tester);
    expect(PublicChats(node, NoteState(node)).joined, [space]);
    // Its messages arrive once joined.
    await tester.runAsync(() => syncPair(node, friend));
    await settled(tester);
    expect(find.text('Catan tonight?'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });
}
