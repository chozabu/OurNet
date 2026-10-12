import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'scope_helpers.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 180)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'navigation creates forums and groups and restores the last destination',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = Node(await LocalIdentity.create(), Store());
      await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
      await settle(tester);
      expect(find.text('Notes'), findsWidgets);
      expect(find.text('Voting'), findsNothing);
      expect(find.text('Home'), findsNothing);
      await tester.tap(find.text('Forums').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start or join a forum'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).last, 'Garden club');
      await tester.tap(find.text('Save'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(
        find.byType(TextField).last,
        'A place for gardeners',
      );
      await tester.tap(find.text('Save'));
      await settle(tester);
      // A forum is called by its name, and has no record of its own.
      const forum = 'garden-club';
      expect(node.subscriptions, contains(forum));
      await tester.tap(find.text('New discussion'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).first, 'Welcome');
      await tester.enterText(
        find.byType(TextField).last,
        'Welcome to the garden',
      );
      await tester.tap(find.text('Publish discussion'));
      await settle(tester);
      expect(node.store.objects(kind: 'post').single.space, forum);
      // The side navigation lists sections only: groups are made from the
      // scope header's picker.
      expect(find.widgetWithText(ListTile, 'Create group'), findsNothing);
      await startCreateGroup(tester);
      await tester.enterText(find.byType(TextField).last, 'Weekend plans');
      await tester.tap(find.text('Save'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(FilledButton, 'Create group').last);
      await settle(tester);
      expect(
        (await tester.runAsync(
          () => Everyday(node).rooms(),
        ))!.single.data['name'],
        'Weekend plans',
      );
      // A new group opens as the scope, at its chat.
      expect(find.byTooltip('Group info'), findsOneWidget);
      expect(find.text('Weekend plans'), findsWidgets);
      await tester.enterText(find.byType(TextField).last, 'Group draft');
      await pickScope(tester, 'All');
      await openSection(tester, 'Notes');
      await settle(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        isEmpty,
      );
      await tester.enterText(find.byType(TextField).last, 'Personal draft');
      await pickScope(tester, 'Weekend plans');
      await openSection(tester, 'Chat');
      await settle(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'Group draft',
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Network and connections'));
      await tester.pumpAndSettle();
      expect(find.text('Network'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Profile and devices'));
      await tester.pumpAndSettle();
      expect(find.text('Edit display name'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Files').first);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
      await settle(tester);
      // Both the destination and the scope (the group) come back.
      expect(find.byTooltip('Group info'), findsOneWidget);
      expect(find.text('Weekend plans'), findsWidgets);
      await pickScope(tester, 'All');
      expect(find.text('Private drive'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
      await settle(tester);
      expect(find.text('Everything you can see'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await node.close();
    },
  );

  testWidgets(
    'attachments include Notes, group and direct files with their scope',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = Node(await LocalIdentity.create(), Store());
      final friend = await LocalIdentity.create();
      await node.addContact(friend.certificate);
      final room = await Everyday(node).createRoom('Family', [friend.person]);
      await Everyday(
        node,
      ).write({'type': 'file', 'name': 'receipt.pdf', 'chunks': [], 'size': 0});
      await Everyday(node).write({
        'type': 'file',
        'name': 'trip.pdf',
        'chunks': [],
        'size': 0,
      }, room: room);
      await node.publish(
        'message',
        {'name': 'letter.pdf', 'chunks': [], 'size': 0},
        space: '_messages',
        audience: [friend.person],
      );
      await node.publish(
        'message',
        {'text': 'Just a message'},
        space: '_messages',
        audience: [friend.person],
      );
      await tester.pumpWidget(
        OurNetApp(
          node: node,
          enablePlatform: false,
          initialTab: Destination.files,
        ),
      );
      await settle(tester);
      await tester.tap(find.text('Attachments'));
      await settle(tester);
      expect(find.text('receipt.pdf'), findsOneWidget);
      expect(find.text('trip.pdf'), findsOneWidget);
      expect(find.text('letter.pdf'), findsOneWidget);
      expect(find.text('Notes · Only you'), findsOneWidget);
      expect(find.text('Family · Private group · 2 members'), findsOneWidget);
      expect(find.byTooltip('Save original'), findsNWidgets(3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await node.close();
    },
  );
}
