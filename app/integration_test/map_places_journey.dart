import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet/ui/map_page.dart';
import 'package:ournet_core/ournet_core.dart';
import 'perf_support.dart';

class _MapCountingNode extends Node {
  int mapReads = 0;
  _MapCountingNode(super.identity, super.store);
  @override
  Future<Json?> content(SignedObject object) {
    if (Places.kinds.contains(object.kind)) mapReads++;
    return super.content(object);
  }
}

/// Included in the list/image acceptance suite: saved rows and map gestures
/// must not reread history or lose an editor draft as map updates arrive.
void savedPlacesHistoryJourney(IntegrationTestWidgetsFlutterBinding binding) {
  testWidgets('saved lists and map stay responsive with a long edit history', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'ournet-map-history-',
    );
    final node = _MapCountingNode(
      await LocalIdentity.create(),
      Store(path: '${directory.path}/profile.db'),
    );
    final places = Places(node);
    final budget =
        1000 / binding.platformDispatcher.views.first.display.refreshRate;
    try {
      node.store.set('mapOnline', false);
      node.store.set('shareLocation', false);
      node.store.set('locationAsked', true);
      const count = 600, versions = 2400;
      // Fixtures are deliberately outside the measured phases.
      final ids = [for (var i = 0; i < count; i++) '${node.person}:pin$i'];
      for (var i = 0; i < versions; i++) {
        final j = i % count;
        await node.publish(
          'map_place',
          {
            'id': ids[j],
            'clock': i + 1,
            'name': 'Place ${j.toString().padLeft(4, '0')}',
            'emoji': '⭐',
            'note': '',
            'lat': 515000000 + j % 30 * 10000,
            'lng': -1200000 + j ~/ 30 * 10000,
          },
          space: Places.personal,
          audience: [node.person],
        );
        if (i < count) {
          await node.publish(
            'map_link',
            {
              'id': '${ids[j]}|saved',
              'place': ids[j],
              'list': Places.saved,
              'clock': 1,
            },
            space: Places.personal,
            audience: [node.person],
          );
        }
      }
      binding.testTextInput.register();
      addTearDown(binding.testTextInput.unregister);
      final opening = Stopwatch()..start();
      await tester.pumpWidget(
        OurNetApp(
          node: node,
          enablePlatform: false,
          initialTab: Destination.maps,
        ),
      );
      for (var i = 0; i < 300 && !places.loaded; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.byTooltip('Saved places'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Place 0000'), findsOneWidget);
      opening.stop();
      node.mapReads = 0;
      final scroll = PhaseRecorder(budget)..start();
      final list = find.byType(ListView).last;
      for (var i = 0; i < 20; i++) {
        await tester.drag(list, Offset(0, i.isEven ? -250 : 250));
        await tester.pump(const Duration(milliseconds: 80));
      }
      final scrolling = await scroll.stop();
      expect(
        node.mapReads,
        0,
        reason:
            'Drawing and scrolling saved rows must not reread stored versions.',
      );
      await tester.tap(find.text('Saved places · Private'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Show on map'));
      await tester.pump(const Duration(seconds: 1));
      final panning = PhaseRecorder(budget)..start();
      for (var i = 0; i < 20; i++) {
        await tester.drag(find.byType(MapPage), Offset(i.isEven ? 45 : -45, 0));
        await tester.pump(const Duration(milliseconds: 150));
      }
      final mapMetrics = await panning.stop();
      expect(node.mapReads, 0);
      await tester.tap(find.byTooltip('Saved places'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Place 0000'));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Details'));
      await tester.pump(const Duration(milliseconds: 400));
      final note = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Note',
      );
      final typing = PhaseRecorder(budget)..start();
      final incoming = () async {
        for (var i = 0; i < 12; i++) {
          await node.publish(
            'map_place',
            {
              'id': ids[1],
              'clock': versions + i + 1,
              'name': 'Updated place',
              'emoji': '⭐',
              'note': '',
              'lat': 515000000,
              'lng': -1200000,
            },
            space: Places.personal,
            audience: [node.person],
          );
        }
      }();
      for (var i = 0; i < 20; i++) {
        await tester.enterText(note, 'Keep this draft $i');
        await tester.pump(const Duration(milliseconds: 60));
      }
      await incoming;
      expect(
        tester.widget<TextField>(note).controller!.text,
        'Keep this draft 19',
      );
      final typingMetrics = await typing.stop();
      (binding.reportData ??= {})['savedPlacesHistory'] = {
        'buildMode': 'profile',
        'places': count,
        'versions': versions,
        'openMs': opening.elapsedMilliseconds,
        'frameBudgetMs': budget,
        'scrolling': scrolling,
        'map': mapMetrics,
        'typing': typingMetrics,
        'incrementalReads': node.mapReads,
      };
      if (const bool.fromEnvironment('PERF_ENFORCE')) {
        expect(opening.elapsedMilliseconds, lessThan(5000));
        for (final phase in [scrolling, mapMetrics, typingMetrics]) {
          expect(phase['frames'] as int, greaterThan(10));
          final frames = phase['frameStageMs'] as Map<String, double>;
          expect(frames['p95'], lessThan(budget));
          expect(frames['p99'], lessThan(2 * budget));
          expect(
            (phase['eventLoopDelayMs'] as Map<String, double>)['max'],
            lessThan(100),
          );
        }
        expect(node.mapReads, lessThanOrEqualTo(12));
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      await node.close();
      await directory.delete(recursive: true);
    }
  });
}
