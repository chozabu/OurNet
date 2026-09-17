import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';

class CountingNode extends Node {
  CountingNode(super.identity, super.store);
  int reads = 0;
  @override
  Future<Json?> content(SignedObject object) {
    reads++;
    return super.content(object);
  }
}

void main() {
  testWidgets('note filters reuse data and changes still refresh it', (
    tester,
  ) async {
    final node = CountingNode(await LocalIdentity.create(), Store());
    addTearDown(node.close);
    await Everyday(node).write({'type': 'note', 'text': 'First note'});
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.notes,
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(find.text('First note'), findsOneWidget);
    final reads = node.reads;
    await tester.tap(find.byTooltip('Show'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, 'Text notes'),
    );
    await tester.pumpAndSettle();
    expect(node.reads, reads);
    expect(find.text('First note'), findsOneWidget);
    await tester.runAsync(
      () => Everyday(node).write({'type': 'note', 'text': 'Second note'}),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Second note'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
