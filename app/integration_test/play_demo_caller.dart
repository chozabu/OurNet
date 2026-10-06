import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/services/calls.dart';
import 'package:ournet/services/network.dart';
import 'package:ournet/services/pairing_discovery.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// A throwaway friend for recording Play Console demo videos: a temporary
/// identity (no personal profile) that offers a friend invitation on the
/// LAN, accepts whoever joins, then calls them when `DEMO_DIR/call` appears
/// and hangs up when `DEMO_DIR/hangup` appears. Run on Windows:
///   flutter test integration_test/play_demo_caller.dart -d windows
///     --dart-define=DEMO_DIR=folder
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('demo caller', timeout: const Timeout(Duration(minutes: 20)), (
    tester,
  ) async {
    const dir = String.fromEnvironment('DEMO_DIR');
    expect(dir, isNotEmpty, reason: 'Pass --dart-define=DEMO_DIR=<folder>');
    bool flag(String name) => File('$dir/$name').existsSync();
    void say(String text) {
      debugPrint('DEMO: $text');
      File('$dir/status.txt').writeAsStringSync('$text\n', mode: FileMode.append);
    }

    final node = Node(await LocalIdentity.create(label: 'Demo PC'), Store());
    await node.publish('profile', {'name': 'Sam (demo)'}, space: '_identity');
    final network = Network(node);
    await network.start();
    final calls = Calls(network);
    await calls.initialise();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Center(child: Text('Demo caller')))),
    );

    String? friend;
    final session = FriendSession(network, (cert, code) async {
      friend = cert.person;
      say('friend joined: ${cert.label}, code $code');
      return true;
    });
    final beacon = await FriendDiscovery.advertise(session);
    say('invitation advertised on the LAN');
    Future<void> until(bool Function() done, Duration limit) async {
      final end = DateTime.now().add(limit);
      while (!done() && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    try {
      await until(() => session.acceptedPeer != null, const Duration(minutes: 5));
      expect(session.acceptedPeer, isNotNull, reason: 'Nobody joined');
      say('friends; waiting for $dir/call');
      await until(() => flag('call'), const Duration(minutes: 10));
      await calls.callPerson(friend!);
      say('calling');
      var last = '';
      await until(() {
        final now = '${calls.phase} ${calls.error ?? ''}';
        if (now != last) say('phase: ${last = now}');
        return flag('hangup');
      }, const Duration(minutes: 5));
      await calls.hangup();
      say('hung up');
      await tester.pump(const Duration(seconds: 2));
    } finally {
      beacon.close();
      session.close();
      await calls.close();
      await network.stop();
    }
  });
}
