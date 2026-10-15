import 'package:flutter/material.dart';
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
  testWidgets('search on Settings filters settings, then searches everything', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
    await settle(tester);
    await tester.tap(find.text('Settings').first);
    await settle(tester);
    expect(find.byTooltip('Search everything'), findsNothing);
    await tester.tap(find.byTooltip('Search settings'));
    await settle(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Search settings'),
      'typing',
    );
    await settle(tester);
    expect(find.text('Typing indicators'), findsOneWidget);
    expect(find.text('Compact spacing'), findsNothing);
    // Subtitles match too.
    await tester.enterText(find.byType(TextField).first, 'passphrase');
    await settle(tester);
    expect(find.text('Save a backup'), findsOneWidget);
    expect(find.text('Typing indicators'), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'garden keys');
    await settle(tester);
    expect(find.text('No settings match'), findsOneWidget);
    await tester.tap(find.text('No settings match'));
    await settle(tester);
    expect(
      find.widgetWithText(
        TextField,
        'Search your notes, conversations and files',
      ),
      findsOneWidget,
    );
    expect(find.text('garden keys'), findsOneWidget);
    // Back on Settings the search starts closed again.
    await tester.tap(find.text('Settings').first);
    await settle(tester);
    await tester.tap(find.byTooltip('Search settings'));
    await settle(tester);
    await tester.tap(find.byTooltip('Close search'));
    await settle(tester);
    expect(find.text('Compact spacing'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await node.close();
  });
}
