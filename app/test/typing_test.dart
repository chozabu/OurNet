import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/typing.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

class HintNetwork extends PeerNetwork {
  HintNetwork(super.node);
  @override
  bool get running => true;
  final sent = <String>[];
  final gates = <String, Completer<Json>>{};
  @override
  Future<Json> request(String device, Json request) {
    sent.add(device);
    return (gates[device] ??= Completer<Json>()).future;
  }
}

void main() {
  test('typing does not queue repeated hints behind a slow device', () async {
    final node = Node(await LocalIdentity.create(), Store());
    final peer = await LocalIdentity.create();
    await node.addContact(peer.certificate);
    final network = HintNetwork(node);
    final typing = Typing(network);
    try {
      network.lastSync[peer.device] = DateTime.now();
      typing.typed(peer.person);
      typing.sent(peer.person);
      typing.typed(peer.person);
      expect(network.sent, [peer.device]);
      network.gates.remove(peer.device)!.complete({});
      await Future<void>.delayed(Duration.zero);
      typing.sent(peer.person);
      typing.typed(peer.person);
      expect(network.sent, [peer.device, peer.device]);
    } finally {
      for (final gate in network.gates.values) {
        gate.complete({});
      }
      typing.dispose();
      await node.close();
    }
  });

  test('typing hints bound outstanding attempts across people', () async {
    final node = Node(await LocalIdentity.create(), Store());
    final network = HintNetwork(node);
    final typing = Typing(network);
    try {
      for (var i = 0; i < 12; i++) {
        final peer = await LocalIdentity.create();
        await node.addContact(peer.certificate);
        network.lastSync[peer.device] = DateTime.now();
        typing.typed(peer.person);
      }
      expect(network.sent, hasLength(8));
    } finally {
      for (final gate in network.gates.values) {
        gate.complete({});
      }
      typing.dispose();
      await node.close();
    }
  });
}
