import 'dart:async';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/note_editor.dart';
import 'package:ournet/services/drafts.dart';
import 'package:ournet_core/ournet_core.dart';

Future<void> settleNotes(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

final itemField = find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText == 'List item',
);

NoteEditorState editorState(WidgetTester tester) =>
    tester.state<NoteEditorState>(find.byType(NoteEditor));

Future<void> flush(WidgetTester tester) async {
  final saving = editorState(tester).flush();
  for (var i = 0; i < 20; i++) {
    var done = false;
    saving.whenComplete(() => done = true);
    await settleNotes(tester);
    if (done) return;
  }
}

void main() {
  const never = Duration(days: 1);
  testWidgets(
    'camera is single flight and ignores a result after editor closes',
    (tester) async {
      final node = Node(await LocalIdentity.create(), Store());
      final notes = Notes(node);
      final picked = Completer<XFile?>();
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: NoteEditor(
            notes: notes,
            drafts: DraftStore(node),
            friends: const {},
            personName: (_) => 'You',
            pickImage: (source) {
              expect(source, ImageSource.camera);
              calls++;
              return picked.future;
            },
          ),
        ),
      );
      final state = editorState(tester);
      final pending = state.addImage(ImageSource.camera);
      await state.addImage(ImageSource.camera);
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox());
      picked.complete(XFile('unused-photo.jpg'));
      await pending;
      expect(tester.takeException(), isNull);
      expect(await notes.list(), isEmpty);
      await node.close();
    },
  );

  testWidgets(
    'cancelled camera can be reopened without creating an empty note',
    (tester) async {
      final node = Node(await LocalIdentity.create(), Store());
      final notes = Notes(node);
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: NoteEditor(
            notes: notes,
            drafts: DraftStore(node),
            friends: const {},
            personName: (_) => 'You',
            pickImage: (_) async {
              calls++;
              return null;
            },
          ),
        ),
      );
      await editorState(tester).addImage(ImageSource.camera);
      await editorState(tester).addImage(ImageSource.camera);
      expect(calls, 2);
      expect(await notes.list(), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await node.close();
    },
  );
  testWidgets(
    'incoming edits preserve unsaved text and saving exposes recovery',
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
            autosaveDelay: never,
          ),
        ),
      );
      await settleNotes(tester);
      final input = find.byKey(const ValueKey('note-text'));
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
      await flush(tester);
      final result = await notes.get(note.id);
      expect(result!.hasConflicts, true);
      expect(result.heads['text']!.map((r) => r.data['value']).toSet(), {
        'Local unsaved writing',
        'Remote writing',
      });
      expect(find.textContaining('Competing writing'), findsOneWidget);
      await tester.tap(find.byTooltip('Collaborators'));
      await tester.pumpAndSettle();
      expect(find.text('Bob'), findsOneWidget);
      expect(
        find.textContaining('current contents and competing versions'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recovery'));
      await tester.pumpAndSettle();
      expect(find.text('Remote writing'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => drafts.flush());
      await a.close();
      await b.close();
    },
  );

  testWidgets('membership change holds an old draft for review, encrypted', (
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
          autosaveDelay: never,
        ),
      ),
    );
    await settleNotes(tester);
    await tester.enterText(
      find.byKey(const ValueKey('note-text')),
      'Draft for review',
    );
    await tester.runAsync(() => notes.changeMembers(note.id, [b.person]));
    await settleNotes(tester);
    await flush(tester);
    expect(
      find.textContaining('Collaborators changed while you were writing'),
      findsOneWidget,
    );
    expect((await notes.get(note.id))!.text, 'Original');
    await tester.pumpWidget(const SizedBox());
    await settleNotes(tester);
    await tester.runAsync(() => drafts.flush());
    expect((await notes.get(note.id))!.text, 'Original');
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

  testWidgets(
    'new lists split lines into items, check them off and keep order',
    (tester) async {
      final a = Node(await LocalIdentity.create(), Store());
      final notes = Notes(a), drafts = DraftStore(a);
      await tester.pumpWidget(
        MaterialApp(
          home: NoteEditor(
            notes: notes,
            checklist: true,
            drafts: drafts,
            friends: const {},
            personName: (_) => 'You',
            autosaveDelay: never,
          ),
        ),
      );
      await settleNotes(tester);
      expect(itemField, findsOneWidget);
      // Nothing is written for an untouched new note.
      await flush(tester);
      expect(await notes.summaries(), isEmpty);
      await tester.enterText(itemField, 'Milk\nEggs\nBread');
      await tester.pump();
      expect(itemField, findsNWidgets(3));
      await flush(tester);
      var saved = (await notes.list()).single;
      expect(saved.checks.map(saved.itemText), ['Milk', 'Eggs', 'Bread']);
      // Checking shows at once and moves the item to the checked section.
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      expect(find.text('1 checked item'), findsOneWidget);
      await flush(tester);
      saved = (await notes.list()).single;
      expect(saved.done(saved.checks.first), true);
      // Enter in the middle of a list inserts directly after that item.
      final eggs = find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == 'Eggs',
      );
      await tester.enterText(eggs, 'Eggs\nButter');
      await tester.pump();
      await flush(tester);
      saved = (await notes.list()).single;
      expect(saved.checks.map(saved.itemText), [
        'Milk',
        'Eggs',
        'Butter',
        'Bread',
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await settleNotes(tester);
      await a.close();
    },
  );

  testWidgets('leaving a new note saves it without pressing anything', (
    tester,
  ) async {
    final a = Node(await LocalIdentity.create(), Store());
    final notes = Notes(a), drafts = DraftStore(a);
    await tester.pumpWidget(
      MaterialApp(
        home: NoteEditor(
          notes: notes,
          drafts: drafts,
          friends: const {},
          personName: (_) => 'You',
          autosaveDelay: never,
        ),
      ),
    );
    await settleNotes(tester);
    await tester.enterText(
      find.byKey(const ValueKey('note-title')),
      'Groceries',
    );
    await tester.enterText(
      find.byKey(const ValueKey('note-text')),
      'Remember the bags',
    );
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5 && (await notes.summaries()).isEmpty; i++) {
      await settleNotes(tester);
    }
    final saved = (await notes.list()).single;
    expect(saved.rawTitle, 'Groceries');
    expect(saved.text, 'Remember the bags');
    expect(saved.hasConflicts, false);
    await a.close();
  });
}
