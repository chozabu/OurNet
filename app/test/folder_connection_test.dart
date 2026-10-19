import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  testWidgets(
    'connected folder fits a phone and disconnect removes only its binding',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = Node(await LocalIdentity.create(), Store());
      final root =
          (await node.content(await Drive(node).folder('Pixel8Pro')))!['entry']
              as String;
      node.store.set('folder-sync/connections', {
        root: {
          'location':
              'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FPixel8Pro',
        },
      });
      await tester.pumpWidget(
        OurNetApp(
          node: node,
          enablePlatform: false,
          initialTab: Destination.files,
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Pixel8Pro'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Pixel8Pro'));
      await tester.pumpAndSettle();
      expect(
        find.text('Connected local folder · two-way sync'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      final card = find.ancestor(
        of: find.text('Connected local folder · two-way sync'),
        matching: find.byType(ListTile),
      );
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: card,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stop syncing here (keep files)'));
      await tester.pumpAndSettle();
      expect(node.store.setting('folder-sync/connections'), isEmpty);
      expect((await Drive(node).entries()).single.current.deleted, false);
      await tester.pumpWidget(const SizedBox());
      await node.close();
    },
  );
  testWidgets(
    'connecting a folder with files on both sides opens the first-sync review',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = Node(await LocalIdentity.create(), Store());
      final local = (await tester.runAsync(() async {
        final docs =
            (await node.content(await Drive(node).folder('Docs')))!['entry']
                as String;
        await Drive(node).write({
          'entry': randomId(),
          'folder': docs,
          'name': 'a.txt',
          'type': 'file',
          'deleted': false,
          'size': 3,
          'chunks': const [],
        });
        final dir = await Directory.systemTemp.createTemp('ournet-connect-');
        await File('${dir.path}/a.txt').writeAsString('local, longer');
        return dir;
      }))!;
      addTearDown(() => local.delete(recursive: true));
      await tester.pumpWidget(
        OurNetApp(
          node: node,
          enablePlatform: false,
          initialTab: Destination.files,
          pickFolder: () async => local.path,
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 4; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pumpAndSettle();
        }
      }

      await settle();
      await tester.scrollUntilVisible(
        find.text('Docs'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      // Clear of the navigation bar along the bottom.
      await tester.drag(
        find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Docs'));
      await settle();
      await tester.scrollUntilVisible(
        find.text('Connect to local folder'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.drag(
        find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect to local folder'));
      for (
        var i = 0;
        i < 50 && find.text('Connect Docs').evaluate().isEmpty;
        i++
      ) {
        if (find.textContaining('Folder connection:').evaluate().isNotEmpty) {
          break;
        }
        await settle();
      }
      expect(find.textContaining('Folder connection:'), findsNothing);
      expect(find.text('Connect Docs'), findsOneWidget);
      expect(find.textContaining('Different on each side'), findsWidgets);
      await tester.tap(find.text('Cancel'));
      await settle();
      expect(node.store.setting('folder-sync/connections'), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(node.close);
    },
  );
  testWidgets(
    'removing a folder with files asks: stop syncing here, or delete it all',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = Node(await LocalIdentity.create(), Store());
      final docs = (await tester.runAsync(() async {
        final id =
            (await node.content(await Drive(node).folder('Docs')))!['entry']
                as String;
        await Drive(node).write({
          'entry': randomId(),
          'folder': id,
          'name': 'a.txt',
          'type': 'file',
          'deleted': false,
          'size': 3,
          'chunks': const [],
        });
        return id;
      }))!;
      node.store.set('folder-sync/connections', {
        docs: {'location': 'content://tree/Docs'},
      });
      await tester.pumpWidget(
        OurNetApp(
          node: node,
          enablePlatform: false,
          initialTab: Destination.files,
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 3; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pumpAndSettle();
        }
      }

      final list = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      Future<void> openDelete() async {
        await settle();
        await tester.scrollUntilVisible(
          find.text('Docs'),
          200,
          scrollable: list,
        );
        await tester.drag(list, const Offset(0, -300));
        await tester.pumpAndSettle();
        final row = find.ancestor(
          of: find.text('Docs'),
          matching: find.byType(ListTile),
        );
        await tester.tap(
          find.descendant(
            of: row,
            matching: find.byType(PopupMenuButton<String>),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete from drive'));
        // The page shows its busy bar under the dialog: pump, not settle.
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
      }

      await openDelete();
      expect(find.text('Remove “Docs” from the drive?'), findsOneWidget);
      expect(
        find.textContaining('It holds 1 file and 0 folders.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Stop syncing here (keep files)'));
      await settle();
      expect(node.store.setting('folder-sync/connections'), isEmpty);
      var entries = (await tester.runAsync(() => Drive(node).entries()))!;
      expect(entries.every((e) => !e.current.deleted), isTrue);

      await openDelete();
      expect(find.text('Stop syncing here (keep files)'), findsNothing);
      await tester.tap(find.text('Delete everything'));
      await settle();
      entries = (await tester.runAsync(() => Drive(node).entries()))!;
      expect(entries.every((e) => e.current.deleted), isTrue);
      expect(find.textContaining('Bad state'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(node.close);
    },
  );
}
