import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  testWidgets(
    'connected folder fits a phone and disconnect removes only its binding',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = Node(await LocalIdentity.create(), Store());
      final root =
          (await node.content(await Drive(node).folder('Pixel8Pro')))!['entry']
              as String;
      node.store.set('folder-sync/connections', {
        root: {
          'location':
              'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FPixel8Pro',
        },
      });
      await tester.pumpWidget(
        OurNetApp(node: node, enablePlatform: false, initialTab: 3),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Pixel8Pro'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Pixel8Pro'));
      await tester.pumpAndSettle();
      expect(
        find.text('Connected local folder · two-way sync'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      final card = find.ancestor(
        of: find.text('Connected local folder · two-way sync'),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(
          of: card,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disconnect (keep files)'));
      await tester.pumpAndSettle();
      expect(node.store.setting('folder-sync/connections'), isEmpty);
      expect((await Drive(node).entries()).single.current.deleted, false);
      await tester.pumpWidget(const SizedBox());
      await node.close();
    },
  );
}
