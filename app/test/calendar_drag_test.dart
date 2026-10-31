import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/controllers/calendar_controller.dart';
import 'package:ournet/ui/calendar_grid.dart';
import 'package:ournet_core/ournet_core.dart';

import 'calendar_test.dart' show tomorrowAt, typeSteady;
import 'chat_features_test.dart' show friends, wide;

/// Drags by mouse from [from] by [by], in steps, as a person would.
Future<void> mouseDrag(WidgetTester tester, Offset from, Offset by) async {
  final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  for (var i = 0; i < 10; i++) {
    await gesture.moveBy(by / 10);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
}

int minutes(Duration d) => d.inMinutes;

void main() {
  testWidgets('dragging in the time grid creates, moves and resizes events', (tester) async {
    wide(tester);
    final (node, _) = await friends(0);
    final c = CalendarController(
      node,
      Calendar(node, NoteState(node)),
      personName: (_) => 'You',
      notify: (message, {action, onAction}) {},
    );
    final start = tomorrowAt(10);
    await tester.runAsync(() async {
      await c.calendar.create(
        Calendar.personal,
        EventDraft(title: 'Standup', start: start, end: start.add(const Duration(hours: 1))),
      );
      await c.refresh();
    });
    final created = <(DateTime, DateTime)>[];
    final moved = <(DateTime, DateTime)>[];
    final day = DateTime(start.year, start.month, start.day);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimeGrid(
            controller: c,
            days: [day],
            onOpen: (_) {},
            onCreate: (s, e) => created.add((s, e)),
            onOpenDay: (_) {},
            onCreateAllDay: (_) {},
            onReschedule: (o, s, e) async => moved.add((s, e)),
          ),
        ),
      ),
    );
    await typeSteady(tester);
    const hour = TimeGrid.hourHeight;
    final block = find.text('Standup');
    expect(block, findsOneWidget);
    final top = tester.getTopLeft(find.ancestor(of: block, matching: find.byType(Opacity)).first);

    // A mouse drag over empty time, two hours below the event.
    final empty = top + const Offset(60, 3 * hour);
    await mouseDrag(tester, empty, const Offset(0, 2 * hour));
    await tester.pumpAndSettle();
    expect(created, hasLength(1));
    // The drag starts once it passes the touch slop, then snaps to 15 minutes.
    expect(minutes(created.single.$2.difference(created.single.$1)), inInclusiveRange(105, 120));

    // A long press by touch makes a half-hour event.
    final gesture = await tester.startGesture(empty, kind: PointerDeviceKind.touch);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(created, hasLength(2));
    expect(minutes(created.last.$2.difference(created.last.$1)), 30);

    // Dragging the event by mouse moves it, keeping its length.
    await mouseDrag(tester, top + const Offset(20, 20), const Offset(0, hour));
    await tester.pumpAndSettle();
    expect(moved, hasLength(1));
    expect(minutes(moved.single.$1.difference(start)), inInclusiveRange(45, 60));
    expect(minutes(moved.single.$2.difference(moved.single.$1)), 60);

    // Dragging its bottom edge resizes it.
    await mouseDrag(tester, top + const Offset(20, hour - 3), const Offset(0, hour / 2));
    await tester.pumpAndSettle();
    expect(moved, hasLength(2));
    expect(moved.last.$1, start);
    expect(minutes(moved.last.$2.difference(start)), inInclusiveRange(75, 90));

    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
