import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';
import 'history_button_test.dart' show settle;

/// Set NETWORK_SHOTS to a folder to also write the page as a PNG.
const _folder = String.fromEnvironment('NETWORK_SHOTS');

Future<void> _shot(WidgetTester tester, String name) async {
  if (_folder.isEmpty) return;
  final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
  final size = tester.view.physicalSize;
  final image = await tester.runAsync(() => layer.toImage(Offset.zero & size));
  final data = await tester.runAsync(
    () => image!.toByteData(format: ui.ImageByteFormat.png),
  );
  await tester.runAsync(
    () => File('$_folder/$name.png').writeAsBytes(data!.buffer.asUint8List()),
  );
}

Future<void> _loadFonts() async {
  const base = 'C:/src/flutter/bin/cache/artifacts/material_fonts';
  Future<ByteData> bytes(String name) async =>
      ByteData.sublistView(await File('$base/$name').readAsBytes());
  await (FontLoader('Roboto')
        ..addFont(bytes('roboto-regular.ttf'))
        ..addFont(bytes('roboto-medium.ttf')))
      .load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(bytes('materialicons-regular.otf'))).load();
}

/// The network page is about connections: own devices are one line that
/// leads to where they are managed, and friends can be found and let go.
void main() {
  testWidgets('friends can be searched and disconnected from', (tester) async {
    if (_folder.isNotEmpty) await tester.runAsync(_loadFonts);
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (node, sam, priya) = (await tester.runAsync(() async {
      final node = Node(await LocalIdentity.create(), Store());
      final friends = <Node>[];
      for (final name in ['Sam', 'Priya']) {
        final friend = Node(await LocalIdentity.create(), Store());
        await node.addContact(friend.identity.certificate);
        await friend.addContact(node.identity.certificate);
        await friend.publish('profile', {'name': name}, space: '_identity');
        await syncPair(friend, node);
        friends.add(friend);
      }
      return (node, friends[0], friends[1]);
    }))!;
    await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
    await settle(tester);
    await tester.tap(find.text('Settings').first);
    await settle(tester);
    await tester.tap(find.text('Network and connections'));
    await settle(tester);

    await _shot(tester, 'network_page');
    expect(find.text('My devices'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Priya'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'pri');
    await settle(tester);
    expect(find.text('Sam'), findsNothing);
    expect(find.text('Priya'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '');
    await settle(tester);

    await tester.tap(find.text('Sam'));
    await settle(tester);
    await tester.tap(find.text('About Sam'));
    await settle(tester);
    await tester.tap(find.text('Disconnect'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await settle(tester);
    expect(node.forgotten, {sam.person});
    expect(node.allowedPeer(sam.identity.device), isFalse);
    expect(node.allowedPeer(priya.identity.device), isTrue);
    expect(find.text('Sam'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await node.close();
  });

  /// Me - Sam - Priya: Priya is not my friend, but Sam's.
  Future<(Node, Node, Node)> friendOfFriend(WidgetTester tester) async =>
      (await tester.runAsync(() async {
        final names = ['Me', 'Sam', 'Priya'];
        final nodes = [
          for (final _ in names) Node(await LocalIdentity.create(), Store()),
        ];
        final [me, sam, priya] = nodes;
        for (final (a, b) in [(me, sam), (sam, priya)]) {
          await a.addContact(b.identity.certificate);
          await b.addContact(a.identity.certificate);
        }
        for (final (i, n) in nodes.indexed) {
          await n.publish('profile', {'name': names[i]}, space: '_identity');
          await n.connections.publish();
        }
        for (var i = 0; i < 2; i++) {
          await syncPair(priya, sam);
          await syncPair(sam, me);
        }
        return (me, sam, priya);
      }))!;

  testWidgets('a friend of a friend can be found and invited', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (node, sam, priya) = await friendOfFriend(tester);
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.network,
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Sam'));
    await settle(tester);
    await tester.tap(find.text('About Sam'));
    await settle(tester);
    expect(find.text('You are friends directly.'), findsOneWidget);
    await tester.tap(find.text('Their friends (1)'));
    await settle(tester);
    await tester.tap(find.text('Priya'));
    await settle(tester);
    expect(find.text('Not connected'), findsOneWidget);
    // The chain: You > Sam > Priya.
    expect(find.widgetWithText(ActionChip, 'Sam'), findsOneWidget);
    await tester.tap(find.text('Invite to connect'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'Sam says hi');
    await tester.tap(find.text('Send request'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await settle(tester);
    final sent = await tester.runAsync(
      () => node.connections.sentTo(priya.person),
    );
    expect(sent?.data['via'], [sam.person]);
    // The note's controller is disposed after the dialog has gone.
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      for (final n in [node, sam, priya]) {
        await n.close();
      }
    });
  });

  testWidgets('a request to connect is shown and accepted', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (node, sam, priya) = await friendOfFriend(tester);
    await tester.runAsync(() async {
      await priya.connections.request(node.person, text: 'Hello from Priya');
      await syncPair(priya, sam);
      await syncPair(sam, node);
    });
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.network,
      ),
    );
    await settle(tester);
    expect(find.text('Priya asks to connect'), findsOneWidget);
    expect(find.textContaining('Hello from Priya'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await settle(tester);
    expect(node.connections.isFriend(priya.person), isTrue);
    expect(find.text('Priya asks to connect'), findsNothing);
    // The answer reaches Priya through Sam, and connects her too.
    await tester.runAsync(() async {
      await syncPair(node, sam);
      await syncPair(sam, priya);
    });
    expect(priya.connections.isFriend(node.person), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      for (final n in [node, sam, priya]) {
        await n.close();
      }
    });
  });
}
