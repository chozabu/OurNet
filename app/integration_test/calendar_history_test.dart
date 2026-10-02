import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';
import 'perf_support.dart';

/// A calendar with years of events opens, pages through its views and takes
/// events arriving from a friend without losing what is being typed.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'long calendar opens, pages through views and takes events arriving',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp('ournet-calendar-');
      final local = Node(
        await LocalIdentity.create(),
        Store(path: '${directory.path}/local.db'),
      );
      final remote = Node(
        await LocalIdentity.create(label: 'Friend'),
        Store(path: '${directory.path}/remote.db'),
      );
      final budget =
          1000 / binding.platformDispatcher.views.first.display.refreshRate;
      try {
        await local.addContact(remote.identity.certificate);
        await remote.addContact(local.identity.certificate);
        await remote.publish('profile', {'name': 'Friend'}, space: '_identity');
        final room = await Everyday(local).createRoom('Shared plans', [remote.person]);
        await syncPair(local, remote);
        final mine = Calendar(local, NoteState(local));
        final theirs = Calendar(remote, NoteState(remote));
        final now = DateTime.now();
        final day = DateTime(now.year, now.month, now.day);
        const total = 3000;
        // About eight years of events, a few of them repeating.
        for (var i = 0; i < total; i++) {
          final start = DateTime(day.year - 4, day.month, day.day + i ~/ 2, 8 + i % 10);
          await mine.create(
            i % 25 == 0 ? room.object.space : Calendar.personal,
            EventDraft(
              title: 'History event $i',
              start: start,
              end: start.add(const Duration(hours: 1)),
              repeat: i % 100 == 0 ? const Repeat('weekly', count: 40) : null,
            ),
          );
        }
        await syncPair(local, remote, rounds: 400);

        binding.testTextInput.register();
        addTearDown(binding.testTextInput.unregister);
        final opening = Stopwatch()..start();
        await tester.pumpWidget(
          OurNetApp(node: local, enablePlatform: false, initialTab: Destination.calendar),
        );
        for (
          var i = 0;
          i < 200 && find.text('Create').evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.text('Create'), findsOneWidget);
        // Today's week has events; wait for the first read of history.
        final soon = DateTime(day.year, day.month, day.day, 9);
        await mine.create(
          Calendar.personal,
          EventDraft(
            title: 'Today marker',
            start: soon,
            end: soon.add(const Duration(hours: 1)),
          ),
        );
        for (
          var i = 0;
          i < 300 && find.text('Today marker').evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        opening.stop();
        expect(find.text('Today marker'), findsOneWidget);

        // Paging forward and back through weeks is frames, not reads.
        final paging = PhaseRecorder(budget)..start();
        for (var i = 0; i < 30; i++) {
          await tester.tap(find.byTooltip(i < 15 ? 'Next' : 'Previous'));
          await tester.pump(const Duration(milliseconds: 60));
        }
        final pagingMetrics = await paging.stop();

        // Switching views over a long history.
        final views = PhaseRecorder(budget)..start();
        for (final view in ['Month', 'Year', 'Schedule', 'Week']) {
          await tester.tap(find.byTooltip('View'));
          await tester.pump(const Duration(milliseconds: 200));
          await tester.tap(find.text(view).last);
          await tester.pump(const Duration(milliseconds: 300));
        }
        final viewMetrics = await views.stop();

        // A friend adds events while a new one is being typed.
        await tester.tap(find.text('Create'));
        await tester.pump(const Duration(milliseconds: 500));
        final title = find.widgetWithText(TextField, 'Add title');
        expect(title, findsOneWidget);
        final typing = PhaseRecorder(budget)..start();
        final incoming = () async {
          final remoteRoom = (await Everyday(remote).rooms()).single;
          for (var i = 0; i < 12; i++) {
            final start = soon.add(Duration(days: 1 + i));
            await theirs.create(
              remoteRoom.object.space,
              EventDraft(
                title: 'Friend event $i',
                start: start,
                end: start.add(const Duration(hours: 1)),
              ),
            );
            await syncPair(local, remote);
          }
        }();
        for (var i = 0; i < 20; i++) {
          await tester.enterText(title, 'Dinner draft $i');
          await tester.pump(const Duration(milliseconds: 50));
        }
        await incoming;
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.widget<TextField>(title).controller!.text, 'Dinner draft 19');
        final typingMetrics = await typing.stop();

        (binding.reportData ??= {})['calendarHistory'] = {
          'buildMode': 'profile',
          'events': total,
          'incomingEvents': 12,
          'openToTodayMs': opening.elapsedMilliseconds,
          'frameBudgetMs': budget,
          'paging': pagingMetrics,
          'views': viewMetrics,
          ...typingMetrics,
        };
        if (const bool.fromEnvironment('PERF_ENFORCE')) {
          for (final m in [pagingMetrics, viewMetrics, typingMetrics]) {
            final frames = m['frameStageMs'] as Map<String, double>;
            final delay = m['eventLoopDelayMs'] as Map<String, double>;
            expect(m['frames'] as int, greaterThan(5));
            expect(frames['p95'], lessThan(budget));
            expect(frames['p99'], lessThan(2 * budget));
            expect(delay['max'], lessThan(100));
          }
          expect(opening.elapsedMilliseconds, lessThan(5000));
        }
      } finally {
        await local.close();
        await remote.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
