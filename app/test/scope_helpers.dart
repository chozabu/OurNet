import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens a destination from the navigation: the side list when wide, the
/// drawer on a phone. The scope stays (docs/SCOPES.md). The navigation lists
/// only sections; scopes are picked from the header ([pickScope]).
Future<void> openSection(WidgetTester tester, String title) async {
  final menu = find.byTooltip('Open navigation menu');
  if (menu.evaluate().isNotEmpty) {
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(Drawer),
            matching: find.widgetWithText(ListTile, title),
          )
          .first,
    );
  } else {
    await tester.tap(find.widgetWithText(ListTile, title).first);
  }
  await tester.pumpAndSettle();
}

/// Picks a scope (All, Personal, Public or a group) from the header.
Future<void> pickScope(WidgetTester tester, String title) async {
  await tester.tap(find.byKey(const ValueKey('scope-header')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byType(BottomSheet),
      matching: find.widgetWithText(ListTile, title),
    ),
  );
  await tester.pumpAndSettle();
}

/// Starts making a group from the header's scope picker, leaving its name
/// dialog open.
Future<void> startCreateGroup(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('scope-header')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byType(BottomSheet),
      matching: find.widgetWithText(ListTile, 'Create group'),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}
