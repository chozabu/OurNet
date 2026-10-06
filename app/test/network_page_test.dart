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
}
