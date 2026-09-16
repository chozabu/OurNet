import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/network.dart';
import 'package:ournet/ui/sync_health.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart' show PeerNetwork;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Node node;
  late Network network;
  late String laptop, friend;
  final now = DateTime(2026, 9, 16, 12);

  setUp(() async {
    final me = await LocalIdentity.create(label: 'Phone');
    node = Node(me, Store());
    final other = await LocalIdentity.create(label: 'WindTop', root: me.root);
    final stranger = await LocalIdentity.create(label: 'Sam phone');
    await node.addContact(other.certificate);
    await node.addContact(stranger.certificate);
    laptop = other.device;
    friend = stranger.device;
    network = Network(node);
    await network.start(local: true, automatic: false);
  });

  tearDown(() async {
    await network.stop();
    await node.close();
  });

  test('a device that never synced and times out is an error', () {
    network.syncErrors[laptop] =
        'TimeoutException after 0:00:15.000000: Future not completed';
    final health = deviceHealth(network, laptop, now: now);
    expect(health.level, HealthLevel.error);
    expect(health.headline, 'Can’t reach WindTop');
    expect(health.details, contains(startsWith('No response')));
    expect(health.details, contains('Never synced'));

    final overall = overallHealth(network, now: now);
    expect(overall.level, HealthLevel.error);
    expect(overall.headline, 'Can’t reach WindTop');
  });

  test('a recent sync turns a failure into a warning', () {
    network.lastSync[laptop] = now.subtract(const Duration(minutes: 5));
    network.syncErrors[laptop] = 'Bad state: Device not admitted';
    final health = deviceHealth(network, laptop, now: now);
    expect(health.level, HealthLevel.warning);
    expect(health.details.first, startsWith('It does not recognise'));
    expect(health.details, contains('Last synced 5 min ago'));
  });

  test('friend devices do not colour the status line', () {
    network.syncErrors[friend] = 'TimeoutException';
    network.lastSync[laptop] = now.subtract(const Duration(minutes: 2));
    expect(deviceHealth(network, friend, now: now).level, HealthLevel.error);
    final overall = overallHealth(network, now: now);
    expect(overall.level, HealthLevel.ok);
    expect(overall.headline, 'Synced 2 min ago');
  });

  test('builds that differ are pointed out', () {
    // Development builds have no stamp to compare against.
    network.peerBuilds[laptop] = '20260916-004729';
    expect(network.build, isEmpty);
    expect(buildNote(network, laptop), isNull);

    final stamped = PeerNetwork(node, build: '20260916-135200');
    expect(buildNote(stamped, laptop), isNull);
    stamped.peerBuilds[laptop] = '20260916-004729';
    expect(
      buildNote(stamped, laptop),
      'Runs build 20260916-004729, older than this one',
    );
    stamped.peerBuilds[laptop] = '20260916-135200';
    expect(buildNote(stamped, laptop), isNull);
  });

  test('stopped network and missing relays are reported', () async {
    expect(overallHealth(network, now: now).headline, contains('waiting'));
    network
      ..local = false
      ..relays = [
        (url: 'https://relay.example', connected: false, error: 'refused'),
      ];
    final relayless = overallHealth(network, now: now);
    expect(relayless.level, HealthLevel.warning);
    expect(relayless.headline, startsWith('No relay'));
    expect(relayless.details, ['refused']);
    await network.stop();
    expect(network.relays, isEmpty);
    expect(overallHealth(network, now: now).level, HealthLevel.offline);
  });

  test('friendly errors keep unknown messages short', () {
    expect(friendlySyncError('Bad state: Something odd'), 'Something odd');
    expect(friendlySyncError('x' * 300).length, 118);
  });

  testWidgets('status line and device text render the failure', (tester) async {
    network.syncErrors[laptop] = 'TimeoutException';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SyncHealthLine(network: network),
              DeviceHealthText(network: network, device: laptop),
              ConnectionHealthCard(network: network, onRestart: () async {}),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Can’t reach WindTop'), findsNWidgets(3));
    expect(find.textContaining('Local mode'), findsOneWidget);

    network.syncErrors.remove(laptop);
    network.lastSync[laptop] = DateTime.now();
    network.notifyListeners();
    await tester.pump();
    expect(find.text('Synced just now'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
}
