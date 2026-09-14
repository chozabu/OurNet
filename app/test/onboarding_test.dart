import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet_core/ournet_core.dart';
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
}
