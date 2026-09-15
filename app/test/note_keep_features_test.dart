import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/drafts.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet/ui/note_card.dart';
import 'package:ournet/ui/note_editor.dart';
import 'package:ournet/ui/note_markup.dart';
import 'package:ournet/ui/note_organise.dart';
import 'package:ournet_core/ournet_core.dart';
import 'features_test.dart' show settled;
import 'note_editor_test.dart' show settleNotes, flush, editorState, itemField;

void main() {
  const never = Duration(days: 1);

  Future<(Node, Notes, DraftStore)> setUpEditor(
    WidgetTester tester, {
    String? id,
    Notes? existing,
    Node? node,
    bool checklist = false,
    void Function(String, bool)? onArchived,
    Future<({String path, String name, int duration, String mime})?> Function(
      BuildContext,
    )?
    recordVoice,
  }) async {
    final a = node ?? Node(await LocalIdentity.create(), Store());
    final notes = existing ?? Notes(a);
    final drafts = DraftStore(a);
    await tester.pumpWidget(
      MaterialApp(
        home: NoteEditor(
          notes: notes,
          id: id,
          checklist: checklist,
          drafts: drafts,
          friends: const {},
          personName: (_) => 'You',
          autosaveDelay: never,
          onArchived: onArchived,
          recordVoice: recordVoice,
        ),
      ),
    );
    await settleNotes(tester);
    return (a, notes, drafts);
  }

  group('markup', () {
    test('plain text removes markers but keeps ordinary asterisks', () {
      expect(
        NoteMarkup.plain('# Trip\n**Pack** *boots* and __maps__'),
        'Trip\nPack boots and maps',
      );
      expect(
        NoteMarkup.plain('2 * 3 * 4 and * bullet'),
        '2 * 3 * 4 and * bullet',
      );
    });

    test('wrapping toggles markers around a selection or word', () {
      var value = const TextEditingValue(
        text: 'buy milk',
        selection: TextSelection.collapsed(offset: 5),
      );
      value = NoteMarkup.wrap(value, '**');
      expect(value.text, 'buy **milk**');
      value = NoteMarkup.wrap(value, '**');
      expect(value.text, 'buy milk');
      value = NoteMarkup.heading(
        const TextEditingValue(
          text: 'one\ntwo',
          selection: TextSelection.collapsed(offset: 5),
        ),
        2,
      );
      expect(value.text, 'one\n## two');
      expect(NoteMarkup.headingAt(value), 2);
      expect(NoteMarkup.heading(value, 0).text, 'one\ntwo');
    });
  });

  test('repeating reminders find their next occurrence', () {
    final start = DateTime(2026, 1, 31, 8);
    final reminder = {'at': start.millisecondsSinceEpoch, 'repeat': 'weekly'};
    expect(
      nextReminder(reminder, DateTime(2026, 2, 3)),
      DateTime(2026, 2, 7, 8),
    );
    expect(
      nextReminder({...reminder, 'repeat': 'none'}, DateTime(2026, 2, 3)),
      isNull,
    );
    expect(
      nextReminder({...reminder, 'repeat': 'daily'}, DateTime(2026, 2, 3, 9)),
      DateTime(2026, 2, 4, 8),
    );
  });

  testWidgets('lists nest items, bulk-uncheck, delete checked and undo', (
    tester,
  ) async {
    final (a, notes, _) = await setUpEditor(tester, checklist: true);
    await tester.enterText(itemField, 'Pack\nSocks\nBoots\nMap');
    await tester.pump();
    await flush(tester);
    final editor = editorState(tester);
    var saved = (await notes.list()).single;
    final [pack, socks, boots, map] = saved.checks;

    // Tab nests an item under the previous one.
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == 'Socks',
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(editor.indentOf(socks), 1);
    editor.setIndent(boots, 1);
    await flush(tester);
    saved = (await notes.get(saved.id))!;
    expect(saved.checks.map(saved.indent), [0, 1, 1, 0]);

    // Checking a parent checks what is nested under it.
    editor.toggle(pack, true);
    await tester.pump();
    expect(find.text('3 checked items'), findsOneWidget);
    // Unchecking a nested item unchecks its parent.
    editor.toggle(socks, false);
    await tester.pump();
    expect(editor.isDone(pack), false);
    editor.toggle(map, true);
    await tester.pump();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uncheck all items'));
    await tester.pumpAndSettle();
    expect(editor.allItems().where(editor.isDone), isEmpty);
    editor.toggle(map, true);
    editor.toggle(boots, true);
    await tester.pump();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete checked items'));
    await tester.pumpAndSettle();
    await flush(tester);
    saved = (await notes.get(saved.id))!;
    expect(saved.checks.map(saved.itemText), ['Pack', 'Socks']);

    // Undo brings the deleted items back, even after they were saved.
    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();
    await flush(tester);
    await flush(tester);
    saved = (await notes.get(saved.id))!;
    expect(saved.checks.map(saved.itemText), ['Pack', 'Socks', 'Boots', 'Map']);
    await tester.tap(find.byTooltip('Redo'));
    await tester.pumpAndSettle();
    await flush(tester);
    saved = (await notes.get(saved.id))!;
    expect(saved.checks.map(saved.itemText), ['Pack', 'Socks']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await settleNotes(tester);
    await a.close();
  });

  testWidgets('text formatting, undo of typing, labels, reminder and archive', (
    tester,
  ) async {
    final a = Node(await LocalIdentity.create(), Store());
    final notes = Notes(a);
    final note = await notes.create(text: 'Hello world');
    final label = await notes.state.createLabel('Home');
    await notes.state.label([note.id], label, true);
    await notes.state.setReminder(
      note.id,
      DateTime.now().add(const Duration(days: 1)),
    );
    String? archived;
    await setUpEditor(
      tester,
      node: a,
      existing: notes,
      id: note.id,
      onArchived: (id, _) => archived = id,
    );
    expect(find.text('Home'), findsOneWidget);
    expect(find.textContaining('Tomorrow'), findsOneWidget);

    final body = find.byKey(const ValueKey('note-text'));
    await tester.tap(body);
    await tester.pump();
    final controller = tester.widget<TextField>(body).controller!;
    controller.selection = const TextSelection(baseOffset: 6, extentOffset: 11);
    await tester.tap(find.byTooltip('Formatting'));
    await tester.pump();
    controller.selection = const TextSelection(baseOffset: 6, extentOffset: 11);
    await tester.tap(find.byTooltip('Bold'));
    await tester.pump();
    expect(controller.text, 'Hello **world**');
    await flush(tester);
    var saved = (await notes.get(note.id))!;
    expect(saved.format, 'markup');
    expect(saved.text, 'Hello **world**');

    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(controller.text, 'Hello world');
    await flush(tester);
    expect((await notes.get(note.id))!.text, 'Hello world');

    await tester.tap(find.byTooltip('Archive'));
    await settleNotes(tester);
    expect(archived, note.id);
    expect(notes.state.archived(note.id), true);
    await tester.pumpWidget(const SizedBox());
    await settleNotes(tester);
    await a.close();
  });

  testWidgets('voice notes show the recording with an editable transcript', (
    tester,
  ) async {
    final a = Node(await LocalIdentity.create(), Store());
    final notes = Notes(a);
    // The attachment worker needs the real clock; attach before the editor
    // starts refreshing on the fake one.
    final (note, file) = (await tester.runAsync(() async {
      final note = await notes.create(title: 'Plumbing');
      final file = await notes.attach(
        note.id,
        note.epoch,
        Stream.value(List.filled(4000, 7)),
        name: 'Recording.m4a',
        meta: {'kind': 'audio', 'mime': 'audio/mp4', 'duration': 4200},
      );
      return (note, file);
    }))!;
    await setUpEditor(tester, node: a, existing: notes, id: note.id);
    final transcript = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'Transcript',
    );
    expect(transcript, findsOneWidget);
    await tester.enterText(transcript, 'Call the plumber');
    await flush(tester);
    expect((await notes.get(note.id))!.transcript(file), 'Call the plumber');
    final summary = (await notes.summaries()).single.data;
    expect(summary['transcript'], 'Call the plumber');
    expect((summary['files'] as List).single['duration'], 4200);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy text'));
    await tester.pumpAndSettle();
    expect(editorState(tester).plainText(), 'Plumbing\nCall the plumber');
    await tester.pumpWidget(const SizedBox());
    await settleNotes(tester);
    await tester.runAsync(a.close);
  });

  testWidgets(
    'home filters archive, reminders and labels; selection acts in bulk',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = Node(await LocalIdentity.create(), Store());
      final notes = Notes(node);
      final plans = await notes.create(title: 'Plans', text: 'Visit the coast');
      final chores = await notes.create(title: 'Chores', items: ['Bins']);
      final old = await notes.create(title: 'Old receipts');
      await notes.state.archive([old.id], true);
      await notes.state.setReminder(
        chores.id,
        DateTime.now().add(const Duration(hours: 3)),
      );
      final label = await notes.state.createLabel('Travel');
      await notes.state.label([plans.id], label, true);
      await tester.pumpWidget(
        OurNetApp(node: node, enablePlatform: false, initialTab: 9),
      );
      await settled(tester);
      expect(find.byType(NoteCard), findsNWidgets(2));
      expect(find.text('Old receipts'), findsNothing);
      expect(find.text('Travel'), findsWidgets);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Archive'));
      await settled(tester);
      expect(find.text('Old receipts'), findsOneWidget);
      expect(find.byType(NoteCard), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Reminders'));
      await settled(tester);
      expect(find.text('Chores'), findsOneWidget);
      expect(find.byType(NoteCard), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Travel'));
      await settled(tester);
      expect(find.text('Plans'), findsOneWidget);
      expect(find.byType(NoteCard), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Notes'));
      await settled(tester);
      // Select both notes with their hover checks, then archive them together.
      for (final title in ['Plans', 'Chores']) {
        final card = find.widgetWithText(NoteCard, title);
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: tester.getCenter(card));
        await tester.pump();
        await tester.tap(
          find.descendant(of: card, matching: find.byTooltip('Select note')),
        );
        await gesture.removePointer();
        await tester.pump();
      }
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.byTooltip('Archive'));
      await settled(tester);
      expect(find.text('2 notes archived'), findsOneWidget);
      // The app has its own Notes; read what it wrote.
      await tester.runAsync(notes.refresh);
      expect(notes.state.archived(plans.id), true);
      expect(notes.state.archived(chores.id), true);
      await tester.tap(find.text('Undo'));
      await settled(tester);
      await tester.runAsync(notes.refresh);
      expect(notes.state.archived(plans.id), false);
      expect(find.byType(NoteCard), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await settled(tester);
      await node.close();
    },
  );
}
