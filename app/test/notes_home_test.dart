import 'dart:io';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet/ui/note_card.dart';
import 'package:ournet_core/ournet_core.dart';
import 'app_test.dart' show snapshot;
import 'features_test.dart' show settled;

void main() {
  setUpAll(() async {
    final font = File('C:/Windows/Fonts/segoeui.ttf');
    if (await font.exists()) {
      await (FontLoader('Roboto')
            ..addFont(font.readAsBytes().then((b) => ByteData.sublistView(b))))
          .load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets(
    'notes grid shows pinned, coloured and list cards, searches and archives',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = Node(await LocalIdentity.create(), Store());
      final friend = await LocalIdentity.create(label: 'Sam');
      await node.addContact(friend.certificate);
      final notes = Notes(node);
      final groceries = await notes.create(
        title: 'Groceries',
        items: ['Oat milk', 'Eggs', 'Tomatoes', 'Coffee beans'],
        color: 'mint',
      );
      await notes.edit(
        groceries.id,
        groceries.epoch,
        'check:${groceries.checks[1]}:done',
        true,
        [],
      );
      await tester.runAsync(() => notes.pin(groceries.id, true));
      final trip = await notes.create(
        title: 'Weekend trip',
        text: 'Leave Friday after work.\nBook the cabin and pack boots.',
        color: 'fog',
      );
      await notes.changeMembers(trip.id, [friend.person]);
      await notes.create(text: 'Door code is on the fridge');
      await notes.create(title: 'Ideas', text: 'A garden bench', color: 'sand');
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture'),
          child: OurNetApp(
            node: node,
            enablePlatform: false,
            initialTab: Destination.notes,
          ),
        ),
      );
      await settled(tester);
      expect(find.text('PINNED'), findsOneWidget);
      expect(find.text('OTHERS'), findsOneWidget);
      expect(find.byType(NoteCard), findsNWidgets(4));
      expect(find.text('1 checked item'), findsOneWidget);
      await snapshot(tester, 'desktop-notes-grid');

      // A card checkbox responds before the note is saved.
      await tester.tap(
        find
            .descendant(
              of: find.widgetWithText(NoteCard, 'Groceries'),
              matching: find.byType(Checkbox),
            )
            .first,
      );
      await tester.pump();
      expect(
        tester
            .widget<Checkbox>(
              find
                  .descendant(
                    of: find.widgetWithText(NoteCard, 'Groceries'),
                    matching: find.byType(Checkbox),
                  )
                  .first,
            )
            .value,
        true,
      );
      await settled(tester);
      expect(find.text('2 checked items'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'cabin');
      await tester.pumpAndSettle();
      expect(find.byType(NoteCard), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();

      // Opening a card shows the Keep-style editor in the note's colour.
      await tester.tap(find.text('Groceries'));
      await settled(tester);
      expect(find.text('2 checked items'), findsOneWidget);
      await snapshot(tester, 'desktop-note-editor');
      await tester.pageBack();
      await settled(tester);

      tester.view.physicalSize = const Size(390, 844);
      await settled(tester);
      await snapshot(tester, 'phone-notes-grid');
      await tester.drag(
        find.widgetWithText(NoteCard, 'Door code is on the fridge'),
        const Offset(-500, 0),
      );
      await settled(tester);
      // Swiping archives, as in Keep; the note stays in Archive.
      expect(find.text('Door code is on the fridge'), findsNothing);
      expect(find.text('Note archived'), findsOneWidget);
      final door = (await notes.summaries()).firstWhere(
        (s) => s.data['body'] == 'Door code is on the fridge',
      );
      expect(notes.state.archived(door.data['entry']), true);
      await tester.tap(find.text('Undo'));
      await settled(tester);
      expect(find.text('Door code is on the fridge'), findsOneWidget);

      tester.view.physicalSize = const Size(390, 844);
      await tester.tap(find.text('Weekend trip'));
      await settled(tester);
      await snapshot(tester, 'phone-note-editor');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await settled(tester);
      await node.close();
    },
  );

  testWidgets('long note lists load in pages while scrolling', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    final notes = Notes(node);
    const count = notesPage * 2 + 10;
    await tester.runAsync(() async {
      for (var i = 0; i < count; i++) {
        await notes.create(title: 'Note $i', text: 'Body of note $i');
      }
    });
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.notes,
      ),
    );
    await settled(tester);
    int? shown() =>
        (tester
                    .widgetList<SliverMasonryGrid>(
                      find.byType(SliverMasonryGrid),
                    )
                    .last
                    .delegate
                as SliverChildBuilderDelegate)
            .childCount;
    expect(find.text('Note ${count - 1}'), findsOneWidget);
    expect(shown(), lessThan(count));

    // A search covers every note, not only the pages shown.
    await tester.enterText(find.byType(TextField).first, 'body of note 0');
    await settled(tester);
    expect(find.text('Note 0'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '');
    await settled(tester);

    // The oldest note is on the last page; scrolling reaches it.
    final list = find.byType(CustomScrollView).last;
    for (var i = 0; i < 40 && find.text('Note 0').evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -2000));
      await tester.pumpAndSettle();
    }
    expect(find.text('Note 0'), findsOneWidget);
    expect(shown(), count);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await settled(tester);
    await node.close();
  });

  testWidgets('dragging a note in a long list writes only its position', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    final notes = Notes(node);
    const count = notesPage * 2 + 30;
    await tester.runAsync(() async {
      for (var i = 0; i < count; i++) {
        await notes.create(title: 'Note $i');
      }
    });
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.notes,
      ),
    );
    await settled(tester);
    await tester.tap(find.byTooltip('List view'));
    await settled(tester);
    List<String> shown() {
      final titles = [
        for (var i = count - 1; i >= count - 5; i--)
          if (find.text('Note $i').evaluate().isNotEmpty) 'Note $i',
      ];
      return titles..sort(
        (a, b) => tester
            .getTopLeft(find.text(a))
            .dy
            .compareTo(tester.getTopLeft(find.text(b)).dy),
      );
    }

    final top = 'Note ${count - 1}', third = 'Note ${count - 3}';
    expect(shown().take(3), [top, 'Note ${count - 2}', third]);
    final version = notes.state.version;
    final from = tester.getCenter(find.widgetWithText(NoteCard, top));
    final to = tester.getCenter(find.widgetWithText(NoteCard, third));
    final drag = await tester.startGesture(from);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    for (var step = 1; step <= 5; step++) {
      await drag.moveTo(Offset.lerp(from, to, step / 5)!);
      await tester.pump();
    }
    // The floating copy follows the pointer while the note is selected.
    expect(find.text(top), findsNWidgets(2));
    expect(find.text('1 selected'), findsOneWidget);
    await drag.up();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await settled(tester);
    expect(shown().take(3), ['Note ${count - 2}', top, third]);
    // The app has its own view of the store; read what was written.
    await tester.runAsync(notes.state.refresh);
    expect(notes.state.version - version, 1);

    // A note written later still appears above the moved note.
    await tester.runAsync(() => notes.create(title: 'Newest'));
    await settled(tester);
    expect(
      tester.getTopLeft(find.text('Newest')).dy,
      lessThan(tester.getTopLeft(find.text(top)).dy),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await settled(tester);
    await node.close();
  });
}
