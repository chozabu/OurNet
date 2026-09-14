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
      await tester.tap(find.widgetWithText(ChoiceChip, 'Lists'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Bring seedlings');
      await tester.tap(find.text('Add'));
      await settled(tester);
      expect(find.text('Bring seedlings'), findsOneWidget);
      await tester.tap(find.byType(Checkbox));
      await settled(tester);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, true);
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
    'group owner can invite with history off and inspect membership',
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
        OurNetApp(node: node, enablePlatform: false, initialTab: 10),
      );
      await settled(tester);
      await tester.tap(find.text('Family').first);
      await settled(tester);
      await tester.tap(find.byTooltip('Group members'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        false,
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
    for (final tab in [10, 2, 1, 3]) {
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture'),
          child: OurNetApp(node: node, enablePlatform: false, initialTab: tab),
        ),
      );
      await settled(tester);
      if (tab == 10) {
        await tester.tap(find.text('Photo club').first);
        await settled(tester);
      }
      expect(
        find.byType(InlineImage),
        findsOneWidget,
        reason: 'Destination $tab',
      );
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      await snapshot(tester, 'desktop-image-$tab');
      if (tab == 3) {
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
