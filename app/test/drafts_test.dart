import 'package:flutter/material.dart';
import 'package:ournet/ui/app.dart';
import 'features_test.dart' show settled;
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/drafts.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  testWidgets(
    'note writing survives reopening and removed notes can be undone',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = Node(await LocalIdentity.create(), Store());
      await Everyday(node).write({'type': 'note', 'text': 'A note to read'});
      await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
      await settled(tester);
      // Opening an older inbox note converts it into an editable note.
      await tester.tap(find.text('A note to read'));
      await settled(tester);
      final body = find.byKey(const ValueKey('note-text'));
      expect(tester.widget<TextField>(body).controller!.text, 'A note to read');
      await tester.enterText(
        body,
        'A note to read'
        '\n'
        'Continue writing later',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await settled(tester);
      await tester.pumpWidget(const SizedBox());
      await settled(tester);
      await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
      await settled(tester);
      expect(find.textContaining('Continue writing later'), findsOneWidget);
      await tester.tap(find.textContaining('Continue writing later'));
      await settled(tester);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove note'));
      await settled(tester);
      expect((await Notes(node).summaries()), isEmpty);
      expect(find.textContaining('Continue writing later'), findsNothing);
      await tester.tap(find.text('Undo'));
      await settled(tester);
      expect(
        (await Notes(node).summaries()).single.data['text'],
        'A note to read'
        '\n'
        'Continue writing later',
      );
      expect(find.textContaining('Continue writing later'), findsOneWidget);
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
