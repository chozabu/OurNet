import 'package:flutter/services.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet/ui/inline_image.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'app_test.dart' show snapshot;

Future<void> settled(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
  }
  // Image loads started by widgets continue in the test zone, so pump them
  // rather than awaiting their completion inside runAsync.
  final loading = find.descendant(
    of: find.byType(Image),
    matching: find.byType(CircularProgressIndicator),
  );
  for (var i = 0; i < 200 && loading.evaluate().isNotEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    final font = File('C:/Windows/Fonts/segoeui.ttf');
    if (await font.exists()) {
      await (FontLoader('Roboto')
            ..addFont(font.readAsBytes().then((b) => ByteData.sublistView(b))))
          .load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets(
    'image previews, personal checklists, search and file source navigation',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = Node(await LocalIdentity.create(), Store());
      final network = PeerNetwork(node);
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('ournet-preview-'),
      ))!;
      final file = File('${dir.path}/garden.png');
      await tester.runAsync(
        () async => file.writeAsBytes(
          await File('test/fixtures/preview.png').readAsBytes(),
        ),
      );
      await tester.runAsync(
        () async => Files(node, network).publish(
          file.path,
          audience: [node.person],
          everyday: await Everyday(node).data({'type': 'file'}),
        ),
      );
      await Everyday(
        node,
      ).write({'type': 'note', 'text': 'Remember the garden keys'});
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture'),
          child: OurNetApp(node: node, enablePlatform: false),
        ),
      );
      await settled(tester);
      expect(find.byType(InlineImage), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      await tester.runAsync(
        () => precacheImage(
          tester.widget<Image>(find.byType(Image)).image,
          tester.element(find.byType(InlineImage)),
        ),
      );
      await tester.pumpAndSettle();
      await snapshot(tester, 'desktop-notes-previews');
      await tester.tap(find.byTooltip('New list'));
      await settled(tester);
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == 'List item',
        ),
        'Bring seedlings',
      );
      await tester.pageBack();
      await settled(tester);
      await settled(tester);
      expect(find.text('Bring seedlings'), findsOneWidget);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, true);
      await settled(tester);
      expect(find.text('1 checked item'), findsOneWidget);
      await tester.tap(find.byTooltip('Search everything'));
      await settled(tester);
      await tester.enterText(find.byType(TextField).first, 'garden');
      await settled(tester);
      expect(find.text('Remember the garden keys'), findsOneWidget);
      expect(find.text('garden.png'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Files'));
      await settled(tester);
      expect(find.text('Remember the garden keys'), findsNothing);
      expect(find.text('garden.png'), findsOneWidget);
      await tester.tap(find.text('Files').first);
      await settled(tester);
      await tester.tap(find.text('Attachments'));
      await settled(tester);
      expect(find.byType(InlineImage), findsOneWidget);
      await tester.tap(find.byTooltip('Open in source'));
      await settled(tester);
      expect(find.text('Notes'), findsWidgets);
      expect(find.text('garden.png'), findsOneWidget);
      tester.view.physicalSize = const Size(390, 844);
      await settled(tester);
      await snapshot(tester, 'phone-notes-previews');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await network.stop();
      await tester.runAsync(node.close);
      await tester.runAsync(() async {
        await file.delete();
        await dir.delete();
      });
    },
  );

  testWidgets(
    'group owner invites without a history choice and inspects membership',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = Node(await LocalIdentity.create(), Store());
      final friend = await LocalIdentity.create(label: 'Friend');
      await node.addContact(friend.certificate);
      await node.publish('profile', {'name': 'Me'}, space: '_identity');
      await Everyday(node).createRoom('Family', []);
      await tester.pumpWidget(
        OurNetApp(
          node: node,
          enablePlatform: false,
          initialTab: Destination.groups,
        ),
      );
      await settled(tester);
      await tester.tap(find.text('Family').first);
      await settled(tester);
      await tester.tap(find.byTooltip('Group members'));
      await tester.pump(const Duration(milliseconds: 300));
      // History is always shared with people joining; the one choice left
      // is whether members add people too, off for this group.
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      await tester.tap(find.byType(CheckboxListTile).last);
      await tester.tap(find.text('Save membership'));
      await settled(tester);
      final room = (await tester.runAsync(
        () => Everyday(node).rooms(),
      ))!.single;
      expect(room.data['members'], contains(friend.person));
      expect(find.text('Conversation'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(node.close);
    },
  );
  testWidgets('a member asks the owner to add a friend, who approves', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Bob owns the group; Carol is in it and knows Dave, whom Bob does not.
    final (bob, carol, dave) = (await tester.runAsync(() async {
      final nodes = <Node>[];
      for (final name in ['Bob', 'Carol', 'Dave']) {
        final n = Node(await LocalIdentity.create(), Store());
        await n.publish('profile', {'name': name}, space: '_identity');
        nodes.add(n);
      }
      final [bob, carol, dave] = nodes;
      for (final (a, b) in [(bob, carol), (carol, dave)]) {
        await a.addContact(b.identity.certificate);
        await b.addContact(a.identity.certificate);
      }
      await Everyday(bob).createRoom('Climbing', [carol.person]);
      await syncPair(carol, dave);
      await syncPair(bob, carol);
      return (bob, carol, dave);
    }))!;
    Future<void> open(Node node) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        OurNetApp(
          node: node,
          enablePlatform: false,
          initialTab: Destination.groups,
        ),
      );
      await settled(tester);
      await tester.tap(find.text('Climbing').first);
      await settled(tester);
    }

    await open(carol);
    await tester.tap(find.byTooltip('Group members'));
    // The dialog is open while the members action runs.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Members (2)'), findsOneWidget);
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Dave'));
    await tester.pump();
    await tester.tap(find.text('Ask owner to add 1'));
    await settled(tester);

    await tester.runAsync(() => syncPair(bob, carol));
    await open(bob);
    expect(find.text('Carol asks you to add Dave'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await settled(tester);
    await settled(tester);
    final room = (await tester.runAsync(() => Everyday(bob).rooms()))!.single;
    expect(room.data['members'], contains(dave.person));
    expect(find.text('Carol asks you to add Dave'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      for (final n in [bob, carol, dave]) {
        await n.close();
      }
    });
  });
  testWidgets('a member adds a friend themselves once the owner lets them', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Bob owns the group; Carol is in it and knows Dave, whom Bob does not.
    final (bob, carol, dave) = (await tester.runAsync(() async {
      final nodes = <Node>[];
      for (final name in ['Bob', 'Carol', 'Dave']) {
        final n = Node(await LocalIdentity.create(), Store());
        await n.publish('profile', {'name': name}, space: '_identity');
        nodes.add(n);
      }
      final [bob, carol, dave] = nodes;
      for (final (a, b) in [(bob, carol), (carol, dave)]) {
        await a.addContact(b.identity.certificate);
        await b.addContact(a.identity.certificate);
      }
      await Everyday(bob).createRoom('Climbing', [carol.person]);
      await Everyday(bob).write({
        'type': 'note',
        'text': 'Wall night Thursday',
      }, room: (await Everyday(bob).rooms()).single);
      await syncPair(carol, dave);
      await syncPair(bob, carol);
      return (bob, carol, dave);
    }))!;
    Future<void> open(Node node) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        OurNetApp(
          node: node,
          enablePlatform: false,
          initialTab: Destination.groups,
        ),
      );
      await settled(tester);
      await tester.tap(find.text('Climbing').first);
      await settled(tester);
    }

    Future<void> members() async {
      await tester.tap(find.byTooltip('Group members'));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // The owner turns it on, once.
    await open(bob);
    await members();
    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Members can add people'),
    );
    await tester.pump();
    expect(find.textContaining('cannot be turned off'), findsOneWidget);
    await tester.tap(find.text('Save membership'));
    await settled(tester);
    await tester.runAsync(() => syncPair(bob, carol));

    await open(carol);
    await members();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Dave'));
    await tester.pump();
    await tester.tap(find.text('Add 1'));
    await settled(tester);
    await settled(tester);
    // Bob is offline; Dave hears from Carol and sees what came before.
    await tester.runAsync(() => syncPair(carol, dave));
    final texts = (await tester.runAsync(() async {
      final everyday = Everyday(dave);
      final room = (await everyday.rooms()).single;
      return [for (final i in await everyday.items(room)) i.data['text']];
    }))!;
    expect(texts, ['Wall night Thursday']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      for (final n in [bob, carol, dave]) {
        await n.close();
      }
    });
  });
  testWidgets('images embed in groups, messages, forums and private drive', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    final friend = await LocalIdentity.create();
    await node.addContact(friend.certificate);
    final network = PeerNetwork(node), everyday = Everyday(node);
    final room = await everyday.createRoom('Photo club', [friend.person]);
    final files = Files(node, network);
    await tester.runAsync(() async {
      final path = File('test/fixtures/preview.png').absolute.path;
      await files.publish(
        path,
        audience: room.object.audience,
        room: room.object.space,
        everyday: await everyday.data({
          'type': 'file',
          'epoch': everyday.epoch(room),
        }),
      );
      await files.publish(path, audience: [friend.person]);
      await files.publish(
        path,
        postSpace: 'general',
        post: {
          'title': 'A sunny afternoon',
          'text': 'A photo from the garden',
          'parent': null,
        },
      );
      await files.publish(
        path,
        audience: [node.person],
        drive: {
          'entry': randomId(),
          'revision': randomId(),
          'folder': null,
          'type': 'file',
          'deleted': false,
          'parents': [],
        },
      );
    });
    for (final tab in [
      Destination.groups,
      Destination.messages,
      Destination.forums,
      Destination.files,
    ]) {
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture'),
          child: OurNetApp(node: node, enablePlatform: false, initialTab: tab),
        ),
      );
      await settled(tester);
      if (tab == Destination.groups) {
        await tester.tap(find.text('Photo club').first);
        await settled(tester);
      }
      expect(
        find.byType(InlineImage),
        findsOneWidget,
        reason: 'Destination $tab',
      );
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      await snapshot(tester, 'desktop-image-${tab.id}');
      if (tab == Destination.files) {
        await tester.tap(find.text('preview.png').first);
        await settled(tester);
        expect(find.text('Drive history'), findsOneWidget);
        expect(find.byType(InlineImage), findsWidgets);
        await tester.tap(find.text('Close'));
        await settled(tester);
      }
      await tester.pumpWidget(const SizedBox());
    }
    await network.stop();
    await tester.runAsync(node.close);
  });
}
