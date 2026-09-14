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
}
