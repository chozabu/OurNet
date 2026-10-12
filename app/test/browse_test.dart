import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/messaging.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';
import 'chat_features_test.dart' show friends, wide;
import 'features_test.dart' show settled;

void main() {
  testWidgets('forums friends follow are listed, and joined from there', (
    tester,
  ) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    await tester.runAsync(() async {
      final theirs = NoteState(friend);
      await theirs.subscribe('cooking', true);
      await Listings(friend, theirs).refresh();
      await syncPair(node, friend);
    });
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.forums,
      ),
    );
    await settled(tester);
    expect(find.text('Friends follow'), findsOneWidget);
    expect(find.text('cooking'), findsOneWidget);
    expect(find.textContaining('1 friend'), findsOneWidget);

    await tester.tap(find.text('Join'));
    await settled(tester);
    expect(node.subscriptions, contains('cooking'));
    expect(find.text('Friends follow'), findsNothing);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });

  testWidgets('a forum link in a message becomes a chip that joins it', (
    tester,
  ) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    await tester.runAsync(() async {
      await sendMessage(
        friend,
        node.person,
        'Try ${Links.forum('cooking')} for recipes',
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
    expect(find.text('cooking'), findsOneWidget);
    await tester.tap(find.text('Join'));
    await settled(tester);
    expect(node.subscriptions, contains('cooking'));

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });
}
