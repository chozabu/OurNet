import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet/ui/conversation_history.dart';
import 'package:ournet_core/ournet_core.dart';
import 'perf_support.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'long conversation retains reading position and draft during sync',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'ournet-conversation-',
      );
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
        for (var i = 0; i < 1005; i++) {
          await remote.publish(
            'message',
            {'text': 'Conversation history $i'},
            audience: [local.person],
            space: '_messages',
          );
        }
        await syncPair(local, remote, rounds: 1000);
        binding.testTextInput.register();
        addTearDown(binding.testTextInput.unregister);
        await tester.pumpWidget(
          OurNetApp(
            node: local,
            enablePlatform: false,
            initialTab: Destination.messages,
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        // Narrow Android layouts open a conversation explicitly.
        if (find.text('Load older messages').evaluate().isEmpty) {
          final tile = find.byType(ListTile).first;
          await tester.tap(tile);
          await tester.pump(const Duration(seconds: 1));
        }
        await tester.tap(find.text('Load older messages'));
        await tester.pump(const Duration(milliseconds: 400));
        final history = find.byWidgetPredicate(
          (w) => w is ListView && w.controller != null,
        );
        await tester.drag(history, const Offset(0, 450));
        await tester.pump(const Duration(milliseconds: 500));
        final controller = tester.widget<ListView>(history).controller!;
        final offset = controller.offset;
        expect(offset, greaterThan(0));
        final composer = find.byType(TextField).last;
        final phase = PhaseRecorder(budget)..start();
        final incoming = () async {
          for (var i = 0; i < 12; i++) {
            await remote.publish(
              'message',
              {'text': 'Incoming $i'},
              audience: [local.person],
              space: '_messages',
            );
            await syncPair(local, remote);
          }
        }();
        for (var i = 0; i < 20; i++) {
          await tester.enterText(composer, 'Draft stays usable $i');
          await tester.pump(const Duration(milliseconds: 50));
        }
        await incoming;
        await tester.pump(const Duration(milliseconds: 300));
        expect(controller.offset, closeTo(offset, 0.1));
        expect(
          tester.widget<TextField>(composer).controller!.text,
          'Draft stays usable 19',
        );
        expect(
          tester.widget<JumpToLatest>(find.byType(JumpToLatest)).pending,
          isTrue,
        );
        final metrics = await phase.stop();
        (binding.reportData ??= {})['conversationHistory'] = {
          'buildMode': 'profile',
          'historyMessages': 1005,
          'incomingMessages': 12,
          'frameBudgetMs': budget,
          ...metrics,
        };
        if (const bool.fromEnvironment('PERF_ENFORCE')) {
          final frames = metrics['frameStageMs'] as Map<String, double>;
          final delay = metrics['eventLoopDelayMs'] as Map<String, double>;
          expect(metrics['frames'] as int, greaterThan(10));
          expect(frames['p95'], lessThan(budget));
          expect(frames['p99'], lessThan(2 * budget));
          expect(delay['max'], lessThan(100));
        }
        await tester.tap(find.byTooltip('Show latest messages'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(controller.offset, 0);
        await tester.tap(find.byIcon(Icons.send));
        await tester.pump(const Duration(seconds: 1));
        expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
        // The chat list's order comes from the latest message, kept as
        // messages arrive rather than found by grouping the history.
        final latest = local.store.recentConversations(local.person).single;
        expect(latest.peer, remote.person);
        expect(
          latest.id,
          local.store
              .conversation(local.person, remote.person, limit: 1)
              .single
              .id,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await local.close();
        await remote.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
