import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    'notes grid shows pinned, coloured and list cards, searches and swipes',
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
      notes.pin(groceries.id, true);
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
          child: OurNetApp(node: node, enablePlatform: false, initialTab: 9),
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
      expect(find.text('Door code is on the fridge'), findsNothing);
      expect(find.text('Note removed'), findsOneWidget);
      expect(
        (await notes.summaries()).map((s) => s.data['body']),
        isNot(contains('Door code is on the fridge')),
      );
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
}
