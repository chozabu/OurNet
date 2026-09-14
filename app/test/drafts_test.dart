import 'package:flutter/material.dart';
import 'package:ournet/ui/app.dart';
import 'features_test.dart' show settled;
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/drafts.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  testWidgets(
    'note drafts survive reopening and notes can be removed and restored',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = Node(await LocalIdentity.create(), Store());
      await Everyday(node).write({'type': 'note', 'text': 'A note to read'});
      await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
      await settled(tester);
      await tester.enterText(
        find.byType(TextField).last,
        'Continue writing later',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await settled(tester);
      await tester.pumpWidget(const SizedBox());
      await settled(tester);
      await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
      await settled(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'Continue writing later',
      );
      await tester.tap(find.text('A note to read'));
      await settled(tester);
      expect(find.widgetWithText(TextField, 'A note to read'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove note'));
      await settled(tester);
      expect((await Notes(node).summaries()), isEmpty);
      await tester.tap(find.byTooltip('Restore note'));
      await settled(tester);
      expect(
        (await Notes(node).summaries()).single.data['text'],
        'A note to read',
      );
      await tester.pumpWidget(const SizedBox());
      await settled(tester);
      await node.close();
    },
  );
  test(
    'drafts persist encrypted, preserve other contexts, and clear after send',
    () async {
      final node = Node(await LocalIdentity.create(), Store());
      final drafts = DraftStore(node);
      await drafts.ready;
      drafts.put('notes/self', 'Private thought', (e) => fail('$e'));
      drafts.put('message/friend', 'Unsent message', (e) => fail('$e'));
      await drafts.flush();
      expect(
        node.store.setting('drafts/v1').toString(),
        isNot(contains('Private thought')),
      );
      final restored = DraftStore(node);
      await restored.ready;
      expect(restored.values['notes/self'], 'Private thought');
      restored.put('notes/self', '', (e) => fail('$e'));
      await restored.flush();
      final again = DraftStore(node);
      await again.ready;
      expect(again.values.containsKey('notes/self'), isFalse);
      expect(again.values['message/friend'], 'Unsent message');
      node.store.close();
    },
  );

  test('typing during restoration wins over the saved draft', () async {
    final node = Node(await LocalIdentity.create(), Store());
    final original = DraftStore(node);
    await original.ready;
    original.put('notes/self', 'Old', (e) => fail('$e'));
    await original.flush();
    final restored = DraftStore(node);
    final loading = restored.ready;
    restored.put('notes/self', 'New', (e) => fail('$e'));
    await loading;
    await restored.flush();
    final finalDraft = DraftStore(node);
    await finalDraft.ready;
    expect(finalDraft.values['notes/self'], 'New');
    node.store.close();
  });
}
