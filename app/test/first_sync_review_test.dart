import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

void main() {
  testWidgets('first-sync review chooses per preset and folder on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    final drive = (await tester.runAsync(() async {
      final object = await Drive(node).write({
        'entry': randomId(),
        'name': 'notes.txt',
        'type': 'file',
        'deleted': false,
        'size': 20,
        'chunks': const [],
      });
      return DriveVersion(object, (await node.content(object))!);
    }))!;
    final plan = FirstSyncPlan('root', '/tmp/phone', [
      FirstSyncItem(
        'notes.txt',
        FirstSyncKind.differs,
        local: FolderItem(false, 't1', 10, null, DateTime(2026, 10, 1)),
        drive: drive,
      ),
      const FirstSyncItem(
        'photos',
        FirstSyncKind.onlyHere,
        local: FolderItem(true, 'directory'),
      ),
      const FirstSyncItem(
        'photos/a.jpg',
        FirstSyncKind.onlyHere,
        local: FolderItem(false, 't2', 2048),
      ),
    ], const []);
    Map<String, Json>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await Navigator.push(
              context,
              MaterialPageRoute<Map<String, Json>>(
                builder: (_) => FirstSyncReview(plan: plan, name: 'Phone'),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Different on each side'), findsWidgets);

    // Everything to the drive, then the photos folder back to keeping both.
    await tester.tap(find.text('Drive wins').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('a.jpg'), 200);
    await tester.tap(find.byTooltip('Choose for everything in photos'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<FirstSyncChoice>, 'Keep both'),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Connect folder'));
    await tester.pumpAndSettle();
    expect(find.text('Move or delete these?'), findsOneWidget);
    expect(find.textContaining('notes.txt'), findsWidgets);
    expect(find.textContaining('photos/a.jpg'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Connect folder').last);
    await tester.pumpAndSettle();
    expect(result, {
      'notes.txt': {
        'keep': 'drive',
        'token': 't1',
        'revision': drive.data['revision'],
      },
    });
    await tester.runAsync(node.close);
  });
}
