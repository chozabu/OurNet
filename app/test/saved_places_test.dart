import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/saved_places.dart';
import 'package:ournet_core/ournet_core.dart';
import 'features_test.dart' show settled;
import 'app_test.dart' show snapshot;
import 'package:ournet/ui/message_text.dart';
import 'package:ournet/ui/place_links.dart';

Widget capture(Widget child) =>
    RepaintBoundary(key: const ValueKey('capture'), child: child);

Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);

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
    'save privately with a complete emoji and find the pin in Saved',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = Node(await LocalIdentity.create(), Store());
      final places = Places(node);
      await places.refresh();
      SavedMapEntry? result;
      await tester.pumpWidget(
        capture(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await editSavedPlace(
                      context,
                      places,
                      lat: 51.5,
                      lng: -.12,
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Private · only you'), findsOneWidget);
      await tester.enterText(field('Place name'), 'Swimming spot');
      await tester.enterText(field('Emoji'), '🏊🏽‍♀️');
      await tester.enterText(field('Note'), 'Use the footpath');
      await tester.pumpAndSettle();
      await snapshot(tester, 'phone-save-place');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settled(tester);
      expect(result?.name, 'Swimming spot');
      expect(result?.emoji, '🏊🏽‍♀️');
      expect(result?.space, Places.personal);
      expect(
        places.inList(Places.personal, Places.saved).single.note,
        'Use the footpath',
      );
      SavedMapEntry? picked;
      await tester.pumpWidget(
        capture(
          MaterialApp(
            home: SavedPlacesPage(
              places: places,
              onSelect: (e) => picked = e,
              onShow: (_) {},
            ),
          ),
        ),
      );
      await settled(tester);
      await tester.enterText(find.byType(TextField), 'footpath');
      await tester.pump();
      expect(find.text('Swimming spot'), findsOneWidget);
      await snapshot(tester, 'phone-saved-places');
      await tester.tap(find.text('Swimming spot'));
      await tester.pump();
      expect(picked?.id, result?.id);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(node.close);
    },
  );

  testWidgets(
    'copying a private pin starts with empty notes and explicit visibility',
    (tester) async {
      final node = Node(await LocalIdentity.create(), Store());
      final places = Places(node);
      final seed = await places.save(
        lat: 1,
        lng: 2,
        name: 'Home',
        note: 'Secret code',
      );
      await places.setPrivateNote(seed, 'Another secret');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => editSavedPlace(
                  context,
                  places,
                  lat: seed.lat,
                  lng: seed.lng,
                  seed: seed,
                ),
                child: const Text('Copy'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Secret code'), findsNothing);
      expect(find.text('Another secret'), findsNothing);
      expect(tester.widget<TextField>(field('Note')).controller!.text, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(node.close);
    },
  );

  testWidgets('saved list keeps a draft while a background update arrives', (
    tester,
  ) async {
    final node = Node(await LocalIdentity.create(), Store());
    final places = Places(node);
    await places.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: SavedPlacesPage(places: places, onSelect: (_) {}, onShow: (_) {}),
      ),
    );
    await settled(tester);
    await tester.enterText(find.byType(TextField), 'Camp');
    await tester.pump();
    await tester.runAsync(() => places.save(lat: 1, lng: 2, name: 'Camp'));
    await settled(tester);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      'Camp',
    );
    expect(find.text('Camp'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(node.close);
  });

  testWidgets('lists can be renamed and deleted without deleting pins', (
    tester,
  ) async {
    final node = Node(await LocalIdentity.create(), Store());
    final places = Places(node);
    final list = await places.createList('Trip');
    final pin = await places.save(lat: 1, lng: 2, name: 'Camp', list: list.id);
    await tester.pumpWidget(
      MaterialApp(
        home: SavedPlacesPage(
          places: places,
          shown: (space: list.space, id: list.id, name: list.name),
          onSelect: (_) {},
          onShow: (_) {},
        ),
      ),
    );
    await settled(tester);
    await tester.tap(find.byTooltip('Rename list'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Holiday');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settled(tester);
    expect(places.lists.single.name, 'Holiday');
    await tester.tap(find.byTooltip('Delete list'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settled(tester);
    expect(places.lists, isEmpty);
    expect(places.all.single.id, pin.id);
    expect(find.text('Camp'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(node.close);
  });

  testWidgets('shared place links open on the map without fetching a preview', (
    tester,
  ) async {
    final place = (lat: 51.5, lng: -.12, name: 'Camp', emoji: '⛺');
    PlaceLink? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaceLinks(
            open: (p) => opened = p,
            child: MessageText(Places.link(place)),
          ),
        ),
      ),
    );
    expect(find.text('Camp'), findsOneWidget);
    await tester.tap(find.byType(ActionChip));
    expect(opened, place);
    expect(MessageText.plain(Places.link(place)), '📍 Camp');
  });
}
