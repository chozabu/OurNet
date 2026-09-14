import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/note_editor.dart';
import 'package:ournet/services/drafts.dart';
import 'package:ournet_core/ournet_core.dart';

Future<void> settleNotes(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 250)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'incoming edits preserve dirty text and saving exposes recovery',
    (tester) async {
      final a = Node(await LocalIdentity.create(), Store());
      final b = Node(await LocalIdentity.create(), Store());
      await a.addContact(b.identity.certificate);
      await b.addContact(a.identity.certificate);
      final notes = Notes(a), other = Notes(b);
      var note = await notes.create(text: 'Initial text');
      await notes.changeMembers(note.id, [b.person]);
      await tester.runAsync(() => syncPair(a, b));
      note = (await notes.get(note.id))!;
      final drafts = DraftStore(a);
      await tester.pumpWidget(
        MaterialApp(
          home: NoteEditor(
            notes: notes,
            id: note.id,
            drafts: drafts,
            friends: {b.person: 'Bob'},
            personName: (id) => id == b.person ? 'Bob' : 'Alice',
          ),
        ),
      );
      await settleNotes(tester);
      final input = find.widgetWithText(TextField, 'Note text');
      await tester.enterText(input, 'Local unsaved writing');
      await tester.runAsync(() async {
        await other.edit(
          note.id,
          note.epoch,
          'text',
          'Remote writing',
          note.parents('text'),
        );
        await syncPair(a, b);
      });
      await settleNotes(tester);
      expect(
        tester.widget<TextField>(input).controller!.text,
        'Local unsaved writing',
      );
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await settleNotes(tester);
      final result = await notes.get(note.id);
      expect(result!.hasConflicts, true);
      expect(result.heads['text']!.map((r) => r.data['value']).toSet(), {
        'Local unsaved writing',
        'Remote writing',
      });
      await tester.tap(find.byTooltip('Collaborators'));
      await tester.pumpAndSettle();
      expect(find.text('Bob'), findsOneWidget);
      expect(
        find.textContaining('current contents and competing versions'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Recovery'));
      await tester.pumpAndSettle();
      expect(find.text('Remote writing'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => drafts.flush());
      await a.close();
      await b.close();
    },
  );

  testWidgets('membership change rejects old draft and retains it encrypted', (
    tester,
  ) async {
    final a = Node(await LocalIdentity.create(), Store());
    final b = Node(await LocalIdentity.create(), Store());
    await a.addContact(b.identity.certificate);
    final notes = Notes(a), drafts = DraftStore(a);
    final note = await notes.create(text: 'Original');
    await tester.pumpWidget(
      MaterialApp(
        home: NoteEditor(
          notes: notes,
          id: note.id,
          drafts: drafts,
          friends: {b.person: 'Bob'},
          personName: (_) => 'Friend',
        ),
      ),
    );
    await settleNotes(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Note text'),
      'Draft for review',
    );
    await tester.runAsync(() => notes.changeMembers(note.id, [b.person]));
    await settleNotes(tester);
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await settleNotes(tester);
    expect(find.textContaining('Collaborators changed.'), findsOneWidget);
    expect((await notes.get(note.id))!.text, 'Original');
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => drafts.flush());
    expect(
      a.store.setting('drafts/v1').toString(),
      isNot(contains('Draft for review')),
    );
    final restored = DraftStore(a);
    await restored.ready;
    expect(restored.values.values.join(), contains('Draft for review'));
    await a.close();
    await b.close();
  });
}
