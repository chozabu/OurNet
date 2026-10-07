import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet/ui/conversation_history.dart';
import 'package:ournet_core/ournet_core.dart';
import 'perf_support.dart';

Finder inChat(String text) => find.descendant(
  of: find.byType(ConversationHistory),
  matching: find.text(text),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'long group chat opens on the newest, pages back and keeps its place',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'ournet-group-chat-',
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
        await remote.publish('profile', {'name': 'Friend'}, space: '_identity');
        await Everyday(local).createRoom('History group', [remote.person]);
        await syncPair(local, remote);
        final theirs = (await Everyday(remote).rooms()).single;
        final base = DateTime.now().millisecondsSinceEpoch - 10000000;
        for (var i = 0; i < 1005; i++) {
          await Everyday(remote).write({
            'type': 'note',
            'text': 'Group history $i',
            'sent': base + i,
          }, room: theirs);
        }
        await syncPair(local, remote, rounds: 1000);
        binding.testTextInput.register();
        addTearDown(binding.testTextInput.unregister);
        await tester.pumpWidget(
          OurNetApp(
            node: local,
            enablePlatform: false,
            initialTab: Destination.groups,
          ),
        );
        for (
          var i = 0;
          i < 100 && find.text('History group').evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.tap(find.text('History group'));
        final opening = Stopwatch()..start();
        while (inChat('Group history 1004').evaluate().isEmpty &&
            opening.elapsed < const Duration(seconds: 10)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        opening.stop();
        expect(inChat('Group history 1004'), findsOneWidget);
        final history = find.byWidgetPredicate(
          (w) => w is ListView && w.controller != null,
        );
        final controller = tester.widget<ListView>(history).controller!;

        // Reading back pages in earlier messages as the end is approached.
        final paging = PhaseRecorder(budget)..start();
        for (
          var i = 0;
          i < 400 && inChat('Group history 0').evaluate().isEmpty;
          i++
        ) {
          controller.jumpTo(controller.position.maxScrollExtent);
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(inChat('Group history 0'), findsOneWidget);
        final pagingMetrics = await paging.stop();

        // Back near the newest, but away from the end of the chat.
        controller.jumpTo(0);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.drag(history, const Offset(0, 450));
        await tester.pump(const Duration(milliseconds: 500));
        final offset = controller.offset;
        expect(offset, greaterThan(0));
        final composer = find.byType(TextField).last;
        final phase = PhaseRecorder(budget)..start();
        final incoming = () async {
          for (var i = 0; i < 12; i++) {
            await Everyday(remote).write({
              'type': 'note',
              'text': 'Group incoming $i',
              'sent': base + 2000 + i,
            }, room: theirs);
            await syncPair(local, remote);
          }
        }();
        for (var i = 0; i < 20; i++) {
          await tester.enterText(composer, 'Draft stays usable $i');
          await tester.pump(const Duration(milliseconds: 50));
        }
        await incoming;
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.widget<TextField>(composer).controller!.text,
          'Draft stays usable 19',
        );
        final metrics = await phase.stop();
        (binding.reportData ??= {})['groupHistory'] = {
          'buildMode': 'profile',
          'historyMessages': 1005,
          'incomingMessages': 12,
          'openToNewestMs': opening.elapsedMilliseconds,
          'frameBudgetMs': budget,
          'paging': pagingMetrics,
          ...metrics,
        };
        if (const bool.fromEnvironment('PERF_ENFORCE')) {
          final frames = metrics['frameStageMs'] as Map<String, double>;
          final delay = metrics['eventLoopDelayMs'] as Map<String, double>;
          expect(metrics['frames'] as int, greaterThan(10));
          expect(frames['p95'], lessThan(budget));
          expect(frames['p99'], lessThan(2 * budget));
          expect(delay['max'], lessThan(100));
          expect(opening.elapsedMilliseconds, lessThan(2000));
        }
        await tester.tap(find.byTooltip('Show latest messages'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(controller.offset, 0);
        expect(inChat('Group incoming 11'), findsOneWidget);
        await tester.tap(find.byIcon(Icons.send));
        await tester.pump(const Duration(seconds: 1));
        expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
        expect(inChat('Draft stays usable 19'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await local.close();
        await remote.close();
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'someone a member adds to a long group reads its history from them',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'ournet-group-invite-',
      );
      Future<Node> node(String name) async => Node(
        await LocalIdentity.create(label: name),
        Store(path: '${directory.path}/$name.db'),
      );
      final owner = await node('owner');
      final member = await node('member');
      final joining = await node('joining');
      try {
        for (final (a, b) in [(owner, member), (member, joining)]) {
          await a.addContact(b.identity.certificate);
          await b.addContact(a.identity.certificate);
        }
        await Everyday(
          owner,
        ).createRoom('History group', [member.person], membersInvite: true);
        final room = (await Everyday(owner).rooms()).single;
        final base = DateTime.now().millisecondsSinceEpoch - 10000000;
        for (var i = 0; i < 1005; i++) {
          await Everyday(owner).write({
            'type': 'note',
            'text': 'Group history $i',
            'sent': base + i,
          }, room: room);
        }
        await syncPair(owner, member, rounds: 1000);
        await Everyday(
          member,
        ).invite((await Everyday(member).rooms()).single, [joining.person]);

        // The owner is offline: everything comes from the member.
        final handOver = Stopwatch()..start();
        await syncPair(member, joining, rounds: 1000);
        handOver.stop();
        final reading = Stopwatch()..start();
        final everyday = Everyday(joining);
        final items = await everyday.items((await everyday.rooms()).single);
        reading.stop();
        expect(items, hasLength(1005));
        expect(items.every((i) => i.object.author == owner.person), isTrue);
        expect(items.any((i) => i.data['history'] == true), isFalse);

        // Once settled, a sync that brings nothing new costs nothing extra.
        final quiet = Stopwatch()..start();
        await syncPair(member, joining);
        quiet.stop();
        (binding.reportData ??= {})['groupInvite'] = {
          'historyMessages': 1005,
          'handOverMs': handOver.elapsedMilliseconds,
          'readAllMs': reading.elapsedMilliseconds,
          'quietSyncMs': quiet.elapsedMilliseconds,
        };
      } finally {
        await owner.close();
        await member.close();
        await joining.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
