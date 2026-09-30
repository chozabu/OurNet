import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet/ui/backup.dart';
import 'package:ournet/ui/onboarding.dart';

void main() {
  testWidgets('fresh phone offers create or connect without creating content', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    addTearDown(node.close);
    await tester.pumpWidget(SetupApp(node: node, discover: false));
    expect(find.text('Create a profile'), findsOneWidget);
    await tester.tap(find.text('Connect to my existing profile'));
    await tester.pumpAndSettle();
    expect(
      find.text('Looking for your other device on this Wi-Fi…'),
      findsOneWidget,
    );
    expect(find.text('Or paste a pairing invitation'), findsOneWidget);
    expect(node.store.count, 0);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create a profile'));
    await tester.pumpAndSettle();
    expect(find.text('Display name'), findsOneWidget);
    expect(find.text('Device name'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a fresh phone offers to restore a backup', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    addTearDown(node.close);
    await tester.pumpWidget(SetupApp(node: node, discover: false));
    expect(find.text('Restore from a backup'), findsOneWidget);
  });

  testWidgets('the backup passphrase is checked before any work starts', (
    tester,
  ) async {
    var worked = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => PassphraseDialog<int>(
                  title: 'Protect',
                  explanation: 'Choose one',
                  confirm: true,
                  action: 'Save backup',
                  working: 'Saving',
                  work: (_) async {
                    worked = true;
                    return 1;
                  },
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'short');
    await tester.tap(find.text('Save backup'));
    await tester.pumpAndSettle();
    expect(find.textContaining('at least 12 characters'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'long enough phrase');
    await tester.enterText(find.byType(TextField).last, 'another long phrase');
    await tester.tap(find.text('Save backup'));
    await tester.pumpAndSettle();
    expect(find.text('The two passphrases do not match'), findsOneWidget);
    expect(worked, isFalse);
    await tester.enterText(find.byType(TextField).last, 'long enough phrase');
    await tester.tap(find.text('Save backup'));
    await tester.pumpAndSettle();
    expect(worked, isTrue);
    expect(find.text('Protect'), findsNothing);
  });
}
