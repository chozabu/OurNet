import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
