import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';
import 'chat_features_test.dart' show friends, say, wide;
import 'features_test.dart' show settled;
import 'scope_helpers.dart';

void main() {
  testWidgets('Activity lists what friends did, filters it by scope and '
      'section, and opens it where it lives', (tester) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    final room = (await tester.runAsync(
      () => Everyday(node).createRoom('Weekend trip', [friend.person]),
    ))!;
    await tester.runAsync(() async {
      await syncPair(node, friend);
      await friend.publish('post', {
        'text': 'Mine keeps dying',
        'title': 'Sourdough help',
      });
      await Notes(
        friend,
      ).create(group: room.object.space, title: 'Packing list');
      await say(friend, node, 'Lunch?');
      await syncPair(node, friend);
    });
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.activity,
      ),
    );
    await settled(tester);

    expect(find.textContaining('started a discussion'), findsOneWidget);
    expect(find.text('Sourdough help'), findsOneWidget);
    expect(find.textContaining('“Packing list”'), findsOneWidget);
    expect(find.textContaining('is now a friend'), findsOneWidget);
    // Chat is off until switched on.
    expect(find.textContaining('sent a message'), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, 'Chat'));
    await settled(tester);
    expect(find.textContaining('sent a message'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'Chat'));
    await settled(tester);

    // Looking at it counts as seen: no badge once it has been open.
    expect(node.store.setting('activitySeen'), isA<int>());

    // A group's scope shows its own activity alone.
    await pickScope(tester, 'Weekend trip');
    await settled(tester);
    expect(find.textContaining('“Packing list”'), findsOneWidget);
    expect(find.text('Sourdough help'), findsNothing);
    await pickScope(tester, 'All');
    await settled(tester);

    // A single post opens its discussion in Forums.
    await tester.tap(find.text('Sourdough help'));
    await settled(tester);
    expect(find.text('Mine keeps dying'), findsWidgets);

    await openSection(tester, 'Activity');
    await settled(tester);
    expect(find.text('Sourdough help'), findsOneWidget);
  });
}
