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

  testWidgets('reachability suggests saving battery when push works', (
    tester,
  ) async {
    Reachability? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              ReachabilityChoice(push: true, onChoose: (c) => chosen = c),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Save battery (suggested)'), findsOneWidget);
    expect(find.text('Always connected'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    expect(chosen, Reachability.batterySaver);
    await tester.tap(find.text('Only check now and then'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    expect(chosen, Reachability.minimal);
  });

  testWidgets('reachability suggests staying connected without push', (
    tester,
  ) async {
    Reachability? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              ReachabilityChoice(push: false, onChoose: (c) => chosen = c),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Always connected (suggested)'), findsOneWidget);
    expect(find.textContaining('not available on this phone'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    expect(chosen, Reachability.alwaysConnected);
  });

  test('each reachability choice maps onto the background settings', () {
    final store = Store();
    addTearDown(store.close);
    storeReachability(store, Reachability.batterySaver);
    expect(store.setting('stayConnected'), false);
    expect(store.setting('pushWake'), true);
    expect(store.setting('backgroundSync'), true);
    storeReachability(store, Reachability.alwaysConnected);
    expect(store.setting('stayConnected'), true);
    expect(store.setting('pushWake'), true);
    storeReachability(store, Reachability.minimal);
    expect(store.setting('stayConnected'), false);
    expect(store.setting('pushWake'), false);
    expect(store.setting('backgroundSync'), true);
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
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump();
    expect(find.textContaining('anyone who gets this file'), findsOneWidget);
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
