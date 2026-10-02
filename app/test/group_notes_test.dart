import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet/ui/note_card.dart';
import 'package:ournet_core/ournet_core.dart';
import 'chat_features_test.dart' show friends, wide;
import 'features_test.dart' show settled;

void main() {
  testWidgets('a group has notes of its own, shared with its members', (
    tester,
  ) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    final room = (await tester.runAsync(
      () => Everyday(node).createRoom('Weekend trip', [friend.person]),
    ))!;
    final notes = Notes(node);
    await tester.runAsync(() async {
      await notes.create(
        group: room.object.space,
        title: 'Packing',
        items: ['Tent', 'Stove'],
      );
      await notes.create(
        group: room.object.space,
        title: 'Route',
        text: 'Lake first',
      );
      await notes.create(title: 'Private shopping', text: 'Not for the group');
    });
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.groups,
      ),
    );
    await settled(tester);
    await tester.tap(find.text('Weekend trip'));
    await settled(tester);
    expect(find.text('Lists'), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Notes'));
    await settled(tester);

    // The group's notes, and only those, as cards on the usual screen.
    expect(find.byType(NoteCard), findsNWidgets(2));
    expect(find.text('Packing'), findsOneWidget);
    expect(find.text('Route'), findsOneWidget);
    expect(find.text('Private shopping'), findsNothing);
    expect(find.text('Search the group\'s notes'), findsOneWidget);

    // Opening one is the ordinary editor; sharing is the group's business.
    await tester.tap(find.text('Route'));
    await settled(tester);
    expect(find.text('Lake first'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });

  testWidgets('old group lists can be imported as notes', (tester) async {
    wide(tester);
    final (node, [friend]) = await friends(1);
    final room = (await tester.runAsync(
      () => Everyday(node).createRoom('Weekend trip', [friend.person]),
    ))!;
    await tester.runAsync(() async {
      for (final (item, done) in [('Tent', true), ('Stove', false)]) {
        await Everyday(node).write({
          'type': 'check',
          'text': item,
          'list': 'Packing',
          'done': done,
        }, room: room);
      }
    });
    await tester.pumpWidget(
      OurNetApp(
        node: node,
        enablePlatform: false,
        initialTab: Destination.groups,
      ),
    );
    await settled(tester);
    await tester.tap(find.text('Weekend trip'));
    await settled(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Notes'));
    await settled(tester);
    expect(
      find.text('This group has a list from before notes'),
      findsOneWidget,
    );
    await tester.tap(find.text('Import'));
    await settled(tester);
    expect(find.text('This group has a list from before notes'), findsNothing);
    expect(find.text('Packing'), findsOneWidget);
    final imported = await tester.runAsync(
      () => Notes(node).list(group: room.object.space),
    );
    final note = imported!.single;
    expect(note.title, 'Packing');
    expect(note.checks.map(note.itemText), ['Tent', 'Stove']);
    expect(note.done(note.checks.first), isTrue);
    expect(note.done(note.checks.last), isFalse);
    // The old items are gone, so a second import finds nothing.
    final left = await tester.runAsync(() => Everyday(node).items(room));
    expect(left!.where((i) => i.data['deleted'] != true), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await node.close();
    await friend.close();
  });
}
