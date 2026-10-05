import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/call_widgets.dart';
import 'package:ournet/ui/group_call_screen.dart';
import 'support/call_rig.dart';

void main() {
  const space = Rig.space;

  /// Lets requests finish and the 200 ms rebuild coalescing fire.
  Future<void> settle() async {
    await pumpEventQueue(times: 100);
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  testWidgets('a group sees who is in a call and can join it', (tester) async {
    final rig = Rig();
    late Dev a, b, watcher;
    await tester.runAsync(() async {
      a = await rig.device('Alex');
      b = await rig.device('Sam');
      watcher = await rig.device('Robin');
      await rig.introduce([a, b, watcher]);
    });
    var joined = 0, video = 0;
    Widget banner() => MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: watcher.calls,
          builder: (context, _) => GroupCallBanner(
            calls: watcher.calls,
            space: space,
            label: (m) => rig.wire.devices[m.device]!.name,
            onJoin: () => joined++,
            onJoinVideo: () => video++,
            onOpen: () {},
          ),
        ),
      ),
    );
    await tester.pumpWidget(banner());
    // No call: nothing to show.
    expect(find.textContaining('Call in progress'), findsNothing);
    expect(find.text('Join'), findsNothing);

    await tester.runAsync(() async {
      await a.calls.join(space);
      await settle();
    });
    await tester.pump();
    expect(find.text('Call in progress · 1 person'), findsOneWidget);
    expect(find.text('Alex'), findsOneWidget);

    await tester.runAsync(() async {
      await b.calls.join(space);
      await settle();
    });
    await tester.pump();
    expect(find.text('Call in progress · 2 people'), findsOneWidget);
    expect(find.text('Alex, Sam'), findsOneWidget);

    await tester.tap(find.text('Join'));
    await tester.tap(find.byTooltip('Join with video'));
    expect([joined, video], [1, 1]);

    await tester.runAsync(() async {
      await a.calls.leave();
      await b.calls.leave();
      await settle();
    });
    await tester.pump();
    // Everyone left: the banner goes away.
    expect(find.textContaining('Call in progress'), findsNothing);
    await tester.runAsync(rig.close);
  });

  testWidgets('the call screen shows everyone and the controls work', (
    tester,
  ) async {
    final rig = Rig();
    late Dev a, b;
    await tester.runAsync(() async {
      a = await rig.device('Alex');
      b = await rig.device('Sam');
      await rig.introduce([a, b]);
      await a.calls.join(space);
      await settle();
      await b.calls.join(space);
      await settle();
    });
    var left = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => GroupCallScreen(
                    calls: b.calls,
                    title: 'Weekend trip',
                    label: (p) =>
                        p.self ? 'You' : rig.wire.devices[p.device]!.name,
                    act: (action) async {
                      await action();
                      left = true;
                    },
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Weekend trip'), findsOneWidget);
    expect(find.textContaining('2 in call'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Alex'), findsOneWidget);

    // Muting shows on this device's own tile.
    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    expect(find.byTooltip('Unmute'), findsOneWidget);
    expect(find.byIcon(Icons.mic_off), findsWidgets);
    expect(b.calls.muted, isTrue);

    // Leaving closes the screen.
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Leave call'));
      await settle();
    });
    await tester.pumpAndSettle();
    expect(left, isTrue);
    expect(b.calls.active, isFalse);
    expect(find.text('Weekend trip'), findsNothing);
    await tester.runAsync(rig.close);
  });

  testWidgets('the list marker counts people in the call', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: GroupCallChip(people: 3))),
    );
    expect(find.text('3'), findsOneWidget);
    expect(find.byTooltip('3 in a call'), findsOneWidget);
  });

  test('the grid makes tiles as large as the screen allows', () {
    // Two on a phone: one above the other.
    expect(gridFor(2, const Size(400, 800)).$1, 1);
    // Two on a desktop window: side by side.
    expect(gridFor(2, const Size(1200, 700)).$1, 2);
    // Four on a desktop: two by two, never a row of slivers.
    final (columns, tile) = gridFor(4, const Size(1200, 700));
    expect(columns, 2);
    expect(tile.width / tile.height, lessThanOrEqualTo(16 / 9 + 1e-9));
    // Many: tiles stay at least portrait 3:4.
    for (var n = 1; n <= 12; n++) {
      final (_, t) = gridFor(n, const Size(390, 700));
      expect(t.width / t.height, greaterThanOrEqualTo(3 / 4 - 1e-9));
      expect(t.width, greaterThan(0));
    }
  });

  testWidgets('tapping someone makes them large; tapping again restores', (
    tester,
  ) async {
    final rig = Rig();
    late Dev a, b, c;
    await tester.runAsync(() async {
      a = await rig.device('Alex');
      b = await rig.device('Sam');
      c = await rig.device('Robin');
      await rig.introduce([a, b, c]);
      for (final d in [a, b, c]) {
        await d.calls.join(space);
        await settle();
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        home: GroupCallScreen(
          calls: c.calls,
          title: 'Weekend trip',
          label: (p) => p.self ? 'You' : rig.wire.devices[p.device]!.name,
          act: (action) => action(),
        ),
      ),
    );
    await tester.pump();
    final alex = find.byKey(ValueKey(a.node.identity.device));
    expect(find.byType(ListView), findsNothing);
    final grid = tester.getSize(alex);

    await tester.tap(find.text('Alex'));
    await tester.pump(const Duration(milliseconds: 300));
    // Alex fills the stage; the others run along a strip.
    expect(find.byType(ListView), findsOneWidget);
    expect(tester.getSize(alex).height, greaterThan(grid.height * 1.5));

    await tester.tap(find.text('Alex'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ListView), findsNothing);

    await tester.runAsync(() async {
      for (final d in [a, b, c]) {
        await d.calls.leave();
      }
      await settle();
    });
    await tester.pump();
    await tester.runAsync(rig.close);
  });

  testWidgets('with two in a call, you float over the other person', (
    tester,
  ) async {
    final rig = Rig();
    late Dev a, b;
    await tester.runAsync(() async {
      a = await rig.device('Alex');
      b = await rig.device('Sam');
      await rig.introduce([a, b]);
      await a.calls.join(space);
      await settle();
      await b.calls.join(space);
      await settle();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: GroupCallScreen(
          calls: b.calls,
          title: 'Weekend trip',
          label: (p) => p.self ? 'You' : rig.wire.devices[p.device]!.name,
          act: (action) => action(),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(FloatingView), findsOneWidget);
    final you = tester.getRect(
      find
          .ancestor(of: find.text('You'), matching: find.byType(Material))
          .first,
    );
    final screen = tester.getRect(find.byType(Scaffold));
    // A small view, settled in the bottom-right corner.
    expect(you.width, lessThan(screen.width / 2));
    expect(you.center.dx, greaterThan(screen.center.dx));
    expect(you.center.dy, greaterThan(screen.center.dy));

    // Dragged towards the top left, it settles in that corner.
    await tester.drag(find.text('You'), const Offset(-600, -900));
    await tester.pumpAndSettle();
    final moved = tester.getRect(
      find
          .ancestor(of: find.text('You'), matching: find.byType(Material))
          .first,
    );
    expect(moved.center.dx, lessThan(screen.center.dx));
    expect(moved.center.dy, lessThan(screen.center.dy));

    await tester.runAsync(() async {
      await a.calls.leave();
      await b.calls.leave();
      await settle();
    });
    await tester.pump();
    await tester.runAsync(rig.close);
  });
}
