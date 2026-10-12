import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app_notice.dart';

void main() {
  late GlobalKey<ScaffoldMessengerState> messenger;

  Future<void> host(WidgetTester tester, {bool accessible = false}) async {
    messenger = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: messenger,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(accessibleNavigation: accessible),
          child: child!,
        ),
        home: const Scaffold(body: SizedBox()),
      ),
    );
  }

  AppNotice undoNotice(String message, VoidCallback undo) => AppNotice(
    content: Text(message),
    duration: const Duration(seconds: 7),
    action: SnackBarAction(label: 'Undo', onPressed: undo),
  );

  for (final message in ['Event saved', 'Event moved']) {
    testWidgets('$message with Undo expires', (tester) async {
      await host(tester);
      final shown = messenger.currentState!.showNotice(
        undoNotice(message, () {}),
      );
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(await shown.closed, SnackBarClosedReason.timeout);
    });
  }

  testWidgets('Undo runs once and dismisses the notice', (tester) async {
    await host(tester);
    var count = 0;
    messenger.currentState!.showNotice(
      undoNotice('Event saved', () => count++),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(count, 1);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('latest notice clears queued stale feedback', (tester) async {
    await host(tester);
    messenger.currentState!.showNotice(undoNotice('First', () {}));
    await tester.pumpAndSettle();
    // Include an existing queue from a caller using Flutter directly.
    messenger.currentState!.showSnackBar(
      const SnackBar(content: Text('Stale')),
    );
    messenger.currentState!.showNotice(undoNotice('Second', () {}));
    messenger.currentState!.showNotice(undoNotice('Latest', () {}));
    await tester.pumpAndSettle();
    expect(find.text('Latest'), findsOneWidget);
    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsNothing);
    expect(find.text('Stale'), findsNothing);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('accessible Undo stays available and can be closed', (
    tester,
  ) async {
    await host(tester, accessible: true);
    var undone = false;
    final shown = messenger.currentState!.showNotice(
      undoNotice('Event moved', () => undone = true),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 20));
    expect(find.text('Undo'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(undone, isFalse);
    expect(await shown.closed, SnackBarClosedReason.dismiss);
  });
}
