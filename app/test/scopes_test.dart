import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';
import 'chat_features_test.dart' show friends, wide;
import 'features_test.dart' show settled;
import 'scope_helpers.dart';

void main() {
  test('the section table keeps calendars and notes out of public', () {
    expect(ScopedSection.calendar.allows(ScopeKind.public), isFalse);
    expect(ScopedSection.notes.allows(ScopeKind.public), isFalse);
    expect(ScopedSection.forums.allows(ScopeKind.personal), isFalse);
    expect(ScopedSection.maps.allows(ScopeKind.group), isFalse);
    for (final section in ScopedSection.values) {
      expect(section.allows(null), isTrue, reason: 'All shows $section');
    }
  });

  testWidgets('a scope stays while moving between sections, and back '
      'unwinds it', (tester) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    final room = (await tester.runAsync(
      () => Everyday(node).createRoom('Weekend trip', [friend.person]),
    ))!;
    await tester.runAsync(() async {
      final notes = Notes(node);
      await notes.create(group: room.object.space, title: 'Packing list');
      await notes.create(title: 'Private shopping');
    });
    await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
    await settled(tester);
    expect(find.text('Everything you can see'), findsOneWidget);
    expect(find.text('Private shopping'), findsOneWidget);

    // Picking the group from the header keeps Notes open, with its notes.
    await pickScope(tester, 'Weekend trip');
    await settled(tester);
    expect(find.text('Packing list'), findsOneWidget);
    expect(find.text('Private shopping'), findsNothing);
    expect(find.byTooltip('Group info'), findsOneWidget);

    // Other sections show the same group.
    await openSection(tester, 'Forums');
    await settled(tester);
    expect(find.byTooltip('Group info'), findsOneWidget);
    expect(find.text('New discussion'), findsWidgets);

    // A group has no map yet: the section says so and offers All.
    await openSection(tester, 'Maps');
    await settled(tester);
    expect(find.text('No maps in Weekend trip'), findsOneWidget);

    // Back goes to Notes in the same group, then to All.
    await tester.binding.handlePopRoute();
    await settled(tester);
    expect(find.text('Packing list'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await settled(tester);
    expect(find.text('Everything you can see'), findsOneWidget);
    expect(find.text('Private shopping'), findsOneWidget);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });

  testWidgets('on a phone, a group is made from the scope picker and opens '
      'as the scope', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (node, [friend]) = await friends(1);
    await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
    await settled(tester);
    await tester.tap(find.byKey(const ValueKey('scope-header')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Create group'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, 'Book club');
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, 'Create group').last);
    await settled(tester);
    expect(find.byTooltip('Group info'), findsOneWidget);
    expect(find.text('Book club'), findsWidgets);
    // Let the creation's notices and sync timers run out.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });

  testWidgets('All lists group chats, forums and notes with your own, and '
      'back returns to the list', (tester) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    final room = (await tester.runAsync(
      () => Everyday(node).createRoom('Weekend trip', [friend.person]),
    ))!;
    await tester.runAsync(() async {
      await syncPair(node, friend);
      final theirs = (await Everyday(friend).rooms()).single;
      await Everyday(
        friend,
      ).write({'type': 'note', 'text': 'Who has the tent?'}, room: theirs);
      await syncPair(node, friend);
      final notes = Notes(node);
      await notes.create(group: room.object.space, title: 'Packing list');
      await notes.create(title: 'Private shopping');
    });
    await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
    await settled(tester);

    // Notes: the group's note is listed in All, named with its group.
    expect(find.text('Private shopping'), findsOneWidget);
    expect(find.text('Packing list'), findsOneWidget);
    expect(find.text('Weekend trip'), findsWidgets);

    // Chat: the group's conversation sits among direct messages.
    await openSection(tester, 'Chat');
    await settled(tester);
    expect(find.textContaining('Who has the tent?'), findsOneWidget);
    await tester.tap(find.textContaining('Who has the tent?'));
    await settled(tester);
    // It opens beside the list, as a conversation does: still in All.
    expect(find.byTooltip('Group info'), findsOneWidget);
    expect(find.text('Everything you can see'), findsOneWidget);
    expect(find.textContaining('Who has the tent?'), findsWidgets);
    expect(find.text('Add friend'), findsOneWidget);
    // And it can become the scope.
    await tester.tap(find.byTooltip('Show only this group'));
    await settled(tester);
    expect(find.text('Everything you can see'), findsNothing);
    expect(find.text('Add friend'), findsNothing);
    await pickScope(tester, 'All');

    // Forums: the group's private forum follows the public ones, and opens
    // beside them.
    await openSection(tester, 'Forums');
    await settled(tester);
    expect(find.text('In your groups · private'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Group forum'));
    await settled(tester);
    expect(find.byTooltip('Group info'), findsOneWidget);
    expect(find.text('In your groups · private'), findsOneWidget);
    expect(find.text('Everything you can see'), findsOneWidget);

    // Personal keeps groups out.
    await pickScope(tester, 'Personal');
    await openSection(tester, 'Notes');
    await settled(tester);
    expect(find.text('Private shopping'), findsOneWidget);
    expect(find.text('Packing list'), findsNothing);
    await openSection(tester, 'Chat');
    await settled(tester);
    expect(find.textContaining('Who has the tent?'), findsNothing);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });

  testWidgets('posts seen in a group forum stop counting as unread', (
    tester,
  ) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    final room = (await tester.runAsync(
      () => Everyday(node).createRoom('Windsworth', [friend.person]),
    ))!;
    await tester.runAsync(() async {
      await syncPair(node, friend);
      final theirs = (await Everyday(friend).rooms()).single;
      final members = await Everyday(friend).members(theirs);
      for (final title in ['Bins', 'Parking', 'Party']) {
        await friend.publish(
          'room_post',
          {'title': title, 'text': 'About $title'},
          space: theirs.object.space,
          audience: members,
        );
      }
      // Stored but never shown: a "shared copy" not from the group's owner.
      // It still has to stop counting once the forum has been read.
      await friend.publish(
        'room_post',
        {'title': 'Ghost', 'text': 'x', 'history': true},
        space: theirs.object.space,
        audience: members,
      );
      await syncPair(node, friend);
    });
    expect(node.unreadSinceFloor('room_post', room.object.space), 4);
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.forums,
      ),
    );
    await settled(tester);
    // The navigation and the group's row both say 4.
    expect(find.text('4'), findsNWidgets(2));
    await tester.tap(find.widgetWithText(ListTile, 'Group forum'));
    await settled(tester);
    expect(find.text('Parking'), findsOneWidget);
    expect(find.text('Ghost'), findsNothing);
    await settled(tester);
    // Read once open: nothing is unread any more, here or in All.
    expect(find.text('4'), findsNothing);
    expect(node.unreadSinceFloor('room_post', room.object.space), 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });

  testWidgets('in All, a new note goes where the capture bar says', (
    tester,
  ) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    final room = (await tester.runAsync(
      () => Everyday(node).createRoom('Weekend trip', [friend.person]),
    ))!;
    await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
    await settled(tester);
    expect(find.text('Take a note…'), findsOneWidget);
    await tester.tap(find.byTooltip('New notes are personal'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, 'Weekend trip'),
    );
    await settled(tester);
    await tester.tap(find.text('Take a note for Weekend trip…'));
    await settled(tester);
    await tester.enterText(
      find.byKey(const ValueKey('note-title')),
      'Campsite ideas',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    final notes = Notes(node);
    List<EverydayItem> inGroup = const [];
    for (var i = 0; i < 10 && inGroup.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      inGroup = (await tester.runAsync(
        () => notes.summaries(group: room.object.space),
      ))!;
    }
    expect(inGroup.single.data['title'], 'Campsite ideas');
    expect((await tester.runAsync(() => notes.summaries()))!, isEmpty);
    await node.close();
    await friend.close();
  });

  testWidgets('Personal and Public show only what they hold', (tester) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.files,
      ),
    );
    await settled(tester);
    expect(find.text('Private drive'), findsOneWidget);
    expect(find.text('Public files'), findsOneWidget);

    await pickScope(tester, 'Public');
    await settled(tester);
    expect(find.text('Private drive'), findsNothing);
    expect(find.text('Public files'), findsOneWidget);

    // Calendars are never public: the section explains, and offers All.
    await openSection(tester, 'Calendar');
    await settled(tester);
    expect(find.text('No calendar in Public'), findsOneWidget);
    await tester.tap(find.text('Show all'));
    await settled(tester);
    expect(find.text('Everything you can see'), findsOneWidget);
    expect(find.text('My calendars'), findsOneWidget);

    await pickScope(tester, 'Personal');
    await settled(tester);
    expect(find.text('My calendars'), findsNothing);
    await openSection(tester, 'Files');
    await settled(tester);
    expect(find.text('Private drive'), findsOneWidget);
    expect(find.text('Public files'), findsNothing);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });
}
