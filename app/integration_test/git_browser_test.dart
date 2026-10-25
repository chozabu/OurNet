import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/ui/git_code_browser.dart';
import 'package:ournet/ui/git_network.dart';
import 'perf_support.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Git code parsing stays interactive and the network pans smoothly',
    (tester) async {
      binding.testTextInput.register();
      addTearDown(binding.testTextInput.unregister);
      final hz = binding.platformDispatcher.views.first.display.refreshRate;
      final budget = 1000 / (hz > 0 ? hz : 60);
      final source = [
        for (var i = 0; i < 10000; i++) 'final value$i = "line $i";',
      ].join('\n');
      final opening = PhaseRecorder(budget)..start();
      final clock = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GitCodeBrowser(
              repository: 'ournet://test/project',
              commit: 'a' * 40,
              path: 'src/sample.dart',
              text: source,
            ),
          ),
        ),
      );
      for (var i = 0; i < 12; i++) {
        await tester.enterText(find.byType(TextField), 'value${i * 10}');
        await tester.pump(const Duration(milliseconds: 50));
      }
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty &&
          clock.elapsedMilliseconds < 10000) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final opened = await opening.stop();
      final code = PhaseRecorder(budget)..start();
      for (var i = 0; i < 12; i++) {
        await tester.drag(find.byType(ListView).last, const Offset(0, -260));
        await tester.pump(const Duration(milliseconds: 70));
      }
      final scrolled = await code.stop();
      final commits = [
        for (var i = 0; i < 128; i++)
          NetworkCommit(
            sha: i.toRadixString(16).padLeft(40, '0'),
            repository: 'project',
            title: 'Commit $i',
            author: 'Test',
            lane: i % 12,
            at: 1700000000000 - i * 1000,
            parents: [
              if (i < 127) (i + 1).toRadixString(16).padLeft(40, '0'),
              if (i % 10 == 0 && i < 125)
                (i + 2).toRadixString(16).padLeft(40, '0'),
            ],
            labels: i < 12 ? ['branch-$i'] : [],
          ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GitNetworkView(
              commits: commits,
              lanes: [for (var i = 0; i < 12; i++) 'Owner / branch-$i'],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final graph = PhaseRecorder(budget)..start();
      for (var i = 0; i < 12; i++) {
        await tester.drag(
          find.byType(InteractiveViewer),
          const Offset(-250, -10),
        );
        await tester.pump(const Duration(milliseconds: 70));
      }
      final panned = await graph.stop();
      (binding.reportData ??= {})['gitBrowser'] = {
        'sourceLines': 10000,
        'graphCommits': 128,
        'frameBudgetMs': budget,
        'openingAndTyping': opened,
        'codeScroll': scrolled,
        'networkPan': panned,
      };
      await tester.pumpWidget(const SizedBox.shrink());
      if (const bool.fromEnvironment('PERF_ENFORCE')) {
        for (final metrics in [opened, scrolled, panned]) {
          final frame = metrics['frameStageMs'] as Map<String, double>;
          final delay = metrics['eventLoopDelayMs'] as Map<String, double>;
          expect(metrics['frames'] as int, greaterThan(5));
          expect(frame['p95'], lessThan(budget));
          expect(frame['p99'], lessThan(2 * budget));
          expect(delay['max'], lessThan(100));
        }
      }
    },
  );
}
