import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 180)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sharing history with another device works from Settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    final friend = Node(await LocalIdentity.create(), Store());
    await node.addContact(friend.identity.certificate);
    await friend.addContact(node.identity.certificate);
    await friend.publish(
      'message',
      {'text': 'hi'},
      space: '_messages',
      audience: [node.person],
    );
    await friend.publish('profile', {'name': 'Friendly'}, space: '_identity');
    final other = Node(
      await LocalIdentity.create(root: node.identity.root, label: 'Laptop'),
      Store(),
    );
    await node.addContact(other.identity.certificate);
    await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
    await settle(tester);
    await tester.tap(find.text('Settings').first);
    await settle(tester);
    await tester.tap(find.text('Profile and devices'));
    await settle(tester);
    await tester.tap(find.byIcon(Icons.history).first);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Share history'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
    final snack = find.byType(SnackBar);
    final texts = [
      for (final w in tester.widgetList<Text>(
        find.descendant(of: snack, matching: find.byType(Text)),
      ))
        w.data,
    ];
    // ignore: avoid_print
    print('SNACKS: $texts');
    expect(texts.join(), isNot(contains('Null check')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await node.close();
  });

  testWidgets('copy diagnostics produces a report', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final node = Node(await LocalIdentity.create(), Store());
    await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
    await settle(tester);
    await tester.tap(find.text('Settings').first);
    await settle(tester);
    await tester.tap(find.text('Copy diagnostics'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(copied, isNotNull);
    expect(copied, contains('"history"'));
    await tester.pumpWidget(const SizedBox());
    await node.close();
  });

  testWidgets('a blocked friend is labelled, and unblocking is one tap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    final friend = Node(await LocalIdentity.create(), Store());
    await node.addContact(friend.identity.certificate);
    node.block(friend.person, true);
    await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
    await settle(tester);
    await tester.tap(find.text('Settings').first);
    await settle(tester);
    await tester.tap(find.text('Network and connections'));
    await settle(tester);
    expect(find.textContaining('(blocked)'), findsWidgets);
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump(const Duration(milliseconds: 300));
    expect(node.blocked, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await node.close();
  });
}
