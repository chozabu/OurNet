import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet/ui/app.dart';

Future<void> snapshot(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/qa/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> publishDiscussion(WidgetTester tester, String text) async {
  await tester.tap(find.text('New discussion'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.enterText(find.byType(TextField).first, 'Discussion topic');
  await tester.enterText(find.byType(TextField).last, text);
  await tester.tap(find.text('Publish discussion'));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    // Real fonts make local Windows QA captures readable. Other hosts keep the
    // standard test font; layout assertions do not depend on screenshot pixels.
    final font = File('C:/Windows/Fonts/segoeui.ttf');
    if (await font.exists()) {
      for (final family in ['Roboto', 'Segoe UI']) {
        final loader = FontLoader(family)
          ..addFont(font.readAsBytes().then((b) => ByteData.sublistView(b)));
        await loader.load();
      }
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  testWidgets('every page lays out on a narrow phone with a known friend', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    final friend = await LocalIdentity.create(label: 'Friend');
    await node.addContact(friend.certificate);
    await Drive(node).folder('Private documents');
    await node.publish('post', {'text': 'A shared community post'});
    await node.publish(
      'message',
      {'text': 'An encrypted conversation'},
      audience: [friend.person],
      space: '_messages',
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture'),
        child: OurNetApp(node: node, enablePlatform: false),
      ),
    );
    await tester.pumpAndSettle();
    for (final title in [
      'Forums',
      'Direct messages',
      'Files',
      'Notes',
      'Private groups',
      'Settings',
    ]) {
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(title).last);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: title);
      if (title == 'Direct messages' ||
          title == 'Locations' ||
          title == 'Files' ||
          title == 'Forums') {
        await snapshot(tester, 'phone-${title.toLowerCase()}');
      }
      if (title == 'Direct messages' || title == 'Forums') {
        await tester.tap(
          title == 'Forums'
              ? find.text('general').first
              : find.byType(CircleAvatar).first,
        );
        await tester.pumpAndSettle();
        // Conversations show a WhatsApp-style back arrow in their header.
        final back = title == 'Forums'
            ? find.text('Back to list')
            : find.byTooltip('Back to list');
        expect(back, findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$title detail');
        await snapshot(tester, 'phone-${title.toLowerCase()}-detail');
        await tester.tap(back);
        await tester.pumpAndSettle();
      }
    }
    await tester.pumpWidget(const SizedBox());
    await node.close();
  });
  testWidgets('own-device call controls fit a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    final fresh = await LocalIdentity.create(label: 'My other laptop');
    final linked = await fresh.enrol(
      await node.identity.authorise(fresh.certificate),
    );
    await node.addContact(linked.certificate);
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.profile,
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byTooltip('Video call device (auto-answer)'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.byTooltip('Call device (auto-answer)'), findsOneWidget);
    expect(find.byTooltip('Remove device access'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await node.close();
  });
  testWidgets('desktop navigation and public post creation', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture'),
        child: OurNetApp(node: node, enablePlatform: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Notes'), findsWidgets);
    await tester.tap(find.text('Forums').first);
    await tester.pumpAndSettle();
    await publishDiscussion(tester, 'An independently verifiable post');
    expect(node.store.objects(kind: 'post').length, 1);
    expect(find.text('An independently verifiable post'), findsOneWidget);
    await snapshot(tester, 'desktop-discussions');
    await tester.tap(find.text('Reply').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'A reply within this discussion',
    );
    await tester.tap(find.byIcon(Icons.send));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(find.text('A reply within this discussion'), findsOneWidget);
    expect(
      node.store
          .objects(kind: 'post')
          .where((o) => o.data['payload']['parent'] != null),
      hasLength(1),
    );
    await tester.tap(find.byTooltip('All discussions'));
    await tester.pumpAndSettle();
    expect(find.text('A reply within this discussion'), findsNothing);
    expect(find.text('An independently verifiable post'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await node.close();
  });
  testWidgets(
    'Shift Enter inserts a newline and Enter sends the composed post',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = Node(await LocalIdentity.create(), Store());
      await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forums').first);
      await tester.pumpAndSettle();
      await publishDiscussion(tester, 'Root discussion');
      await tester.tap(find.text('Reply').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'First line');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(node.store.objects(kind: 'post'), hasLength(1));
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'First line\n',
      );
      await tester.enterText(
        find.byType(TextField).last,
        'First line\nSecond line',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      expect(
        node.store
            .objects(kind: 'post')
            .firstWhere((o) => o.data['payload']['parent'] != null)
            .data['payload']['text'],
        'First line\nSecond line',
      );
      await tester.pumpWidget(const SizedBox());
      await node.close();
    },
  );
  testWidgets(
    'mobile drawer works and shows an honest empty conversation state',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = Node(await LocalIdentity.create(), Store());
      await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Direct messages'));
      await tester.pumpAndSettle();
      expect(find.text('Start a conversation'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await node.close();
    },
  );
  testWidgets('private and community drafts remain separate when navigating', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    await node.addContact((await LocalIdentity.create()).certificate);
    await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Direct messages').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Private draft');
    await tester.tap(find.text('Forums').first);
    await tester.pumpAndSettle();
    await publishDiscussion(tester, 'Root for draft test');
    await tester.tap(find.text('Reply').first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      isEmpty,
    );
    await tester.enterText(find.byType(TextField).last, 'Public draft');
    await tester.tap(find.text('Direct messages').first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      'Private draft',
    );
    await tester.pumpWidget(const SizedBox());
    await node.close();
  });
}
