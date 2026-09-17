import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';
import 'features_test.dart' show settled;

void main() {
  testWidgets('conversation paging and incoming updates preserve draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    final friend = await LocalIdentity.create(label: 'Friend');
    await node.addContact(friend.certificate);
    for (var i = 0; i < 55; i++) {
      await node.publish(
        'message',
        {'text': 'History $i'},
        audience: [friend.person],
        space: '_messages',
      );
    }
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.messages,
      ),
    );
    await settled(tester);
    expect(find.text('Load older messages'), findsOneWidget);
    final composer = find.byType(TextField).last;
    await tester.enterText(composer, 'Keep this draft');
    await tester.tap(find.text('Load older messages'));
    await settled(tester);
    expect(find.text('Load older messages'), findsNothing);
    await tester.runAsync(
      () => node.publish(
        'message',
        {'text': 'Arrived during typing'},
        audience: [friend.person],
        space: '_messages',
      ),
    );
    await settled(tester);
    expect(
      tester.widget<TextField>(composer).controller!.text,
      'Keep this draft',
    );
    expect(find.text('Arrived during typing'), findsWidgets);
    expect(find.text('Load older messages'), findsNothing);
    await tester.tap(find.byIcon(Icons.send));
    await settled(tester);
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
    expect(node.store.conversation(node.person, friend.person).length, 50);
    final history = find.byWidgetPredicate(
      (w) => w is ListView && w.controller != null,
    );
    // Reversed chat list: dragging down reveals older messages.
    await tester.drag(history, const Offset(0, 500));
    await settled(tester);
    final controller = tester.widget<ListView>(history).controller!;
    final offset = controller.offset;
    expect(offset, greaterThan(0));
    final count = tester
        .widget<ListView>(history)
        .childrenDelegate
        .estimatedChildCount;
    await tester.enterText(composer, 'Still typing');
    await tester.runAsync(
      () => node.publish(
        'message',
        {'text': 'Do not jump'},
        audience: [friend.person],
        space: '_messages',
      ),
    );
    await settled(tester);
    expect(find.text('Show latest messages'), findsOneWidget);
    expect(controller.offset, closeTo(offset, 0.1));
    expect(
      tester.widget<ListView>(history).childrenDelegate.estimatedChildCount,
      count,
    );
    expect(tester.widget<TextField>(composer).controller!.text, 'Still typing');
    await tester.tap(find.text('Show latest messages'));
    await settled(tester);
    expect(controller.offset, 0);
    expect(find.text('Do not jump'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
  });
}
