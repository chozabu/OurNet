import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet/ui/wall_page.dart';
import 'package:ournet_core/ournet_core.dart';
import 'chat_features_test.dart' show friends, wide;
import 'features_test.dart' show settled;
import 'scope_helpers.dart';

void main() {
  testWidgets('Activity shows friends\' wall posts as cards, posts to friends '
      'and takes comments', (tester) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    await tester.runAsync(() async {
      final theirs = Wall(friend, friend.person);
      await theirs.publish('Back from the hills');
      await theirs.publish('Photos soon', audience: WallAudience.public);
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
    // Walls are in Activity, not a section of their own.
    expect(find.widgetWithText(ListTile, 'Wall'), findsNothing);
    expect(find.byType(WallPostCard), findsNWidgets(2));
    expect(find.text('Back from the hills'), findsOneWidget);
    expect(find.text('Photos soon'), findsOneWidget);
    // Only a public post can be shared on.
    expect(find.widgetWithText(TextButton, 'Share'), findsOneWidget);

    // Public shows public posts alone.
    await pickScope(tester, 'Public');
    await settled(tester);
    expect(find.text('Back from the hills'), findsNothing);
    expect(find.text('Photos soon'), findsOneWidget);
    await pickScope(tester, 'All');
    await settled(tester);

    // The Wall filter hides the cards and the composer with them.
    await tester.tap(find.widgetWithText(FilterChip, 'Wall'));
    await settled(tester);
    expect(find.byType(WallPostCard), findsNothing);
    expect(find.byType(WallComposer), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, 'Wall'));
    await settled(tester);

    // A post of one's own, to friends by default.
    await tester.enterText(
      find.widgetWithText(TextField, 'What is new?'),
      'Hello everyone',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Post'));
    await settled(tester);
    // One's own post shows in Activity too, as a card.
    expect(
      find.ancestor(
        of: find.text('Hello everyone'),
        matching: find.byType(WallPostCard),
      ),
      findsOneWidget,
    );
    final mine = node.store.objects(kind: Walls.postKind, author: node.person);
    expect(Walls.sealed(mine.single.data['payload'] as Json), isTrue);

    // A comment on the friend's friends-only post.
    final card = find.ancestor(
      of: find.text('Back from the hills'),
      matching: find.byType(WallPostCard),
    );
    await tester.tap(
      find.descendant(
        of: card,
        matching: find.widgetWithText(TextButton, 'Comment'),
      ),
    );
    await settled(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Write a comment for their friends'),
      'Looks lovely',
    );
    await tester.tap(find.byTooltip('Send'));
    await settled(tester);
    expect(find.text('Looks lovely'), findsOneWidget);
    await tester.runAsync(() => syncPair(node, friend));
    final view = Wall(friend, friend.person);
    await tester.runAsync(view.refresh);
    expect(
      view.posts.map((p) => p.comments.map((c) => c.text)).expand((t) => t),
      ['Looks lovely'],
    );
  });
}
