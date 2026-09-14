import 'package:flutter_test/flutter_test.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:ournet/services/pairing_discovery.dart';

void main() {
  test('nearby discovery advertises only an open pairing session', () async {
    final node = Node(await LocalIdentity.create(label: 'Nearby PC'), Store());
    final network = PeerNetwork(node);
    await network.start(local: true, automatic: false);
    final session = PairingSession(network, (_, _) async => false);
    final socket = await PairingDiscovery.advertise(session);
    try {
      expect(await PairingDiscovery.find(), contains(session.invitation));
      session.close();
      expect(await PairingDiscovery.find(), isEmpty);
    } finally {
      socket.close();
      await network.stop();
      await node.close();
    }
  });

  test('nearby friend discovery shares only an open invitation', () async {
    final node = Node(await LocalIdentity.create(label: 'Sam phone'), Store());
    final network = PeerNetwork(node);
    await network.start(local: true, automatic: false);
    final session = FriendSession(network, (_, _) async => false);
    final socket = await FriendDiscovery.advertise(session);
    try {
      expect(await FriendDiscovery.find(), contains(session.invitation));
      // Pairing discovery never reveals a friend invitation, and vice versa.
      expect(await PairingDiscovery.find(), isEmpty);
      session.close();
      expect(await FriendDiscovery.find(), isEmpty);
    } finally {
      socket.close();
      await network.stop();
      await node.close();
    }
  });
}
