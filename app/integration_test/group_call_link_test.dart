import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/services/call_link.dart';

/// Two real native WebRTC links negotiated against each other in one process,
/// the way a pair of devices in a group call do: the offerer's transceivers,
/// the answerer binding to the offer's, candidates in bursts, then an ICE
/// restart on the live link. No microphone or camera needed.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('two links connect, and survive an ICE restart', (tester) async {
    final a = await WebRtcLink.create(device: 'a', iceServers: const []);
    final b = await WebRtcLink.create(device: 'b', iceServers: const []);
    addTearDown(() async {
      await a.close();
      await b.close();
    });
    a.onCandidates = (c) => unawaited(b.addCandidates(c));
    b.onCandidates = (c) => unawaited(a.addCandidates(c));
    final answer = await b.accept(await a.createOffer());
    await a.acceptAnswer(answer);
    Future<void> until(LinkState state) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline) ||
          a.state != state ||
          b.state != state) {
        if (a.state == state && b.state == state) return;
        if (DateTime.now().isAfter(deadline)) break;
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      }
      fail('links are ${a.state} / ${b.state}, wanted $state');
    }

    await until(LinkState.connected);
    await a.poll();
    expect(a.rttMs, isNotNull);
    // Each side's renderer has the other's stream: on Android it comes from
    // onAddStream, which needs both sides to label what they send.
    for (var i = 0; i < 50; i++) {
      if (a.renderer!.srcObject != null && b.renderer!.srcObject != null) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    expect(a.renderer!.srcObject, isNotNull);
    expect(b.renderer!.srcObject, isNotNull);

    final restart = await b.accept(await a.createOffer(restart: true));
    await a.acceptAnswer(restart);
    await until(LinkState.connected);
  });
}
