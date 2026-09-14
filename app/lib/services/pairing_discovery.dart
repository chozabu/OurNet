import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ournet_transport/ournet_transport.dart';

/// Same-network discovery of an open invitation. Answers carry only the
/// invitation that is already shown as a QR code; approval still requires
/// comparing codes on the inviting device.
class _Beacon {
  final int port;
  final String probe;
  final void Function(String) parse;
  const _Beacon(this.port, this.probe, this.parse);

  Future<RawDatagramSocket> advertise(
    bool Function() available,
    String Function() invitation,
  ) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final packet = socket.receive();
      if (packet != null &&
          available() &&
          utf8.decode(packet.data, allowMalformed: true) == probe) {
        socket.send(utf8.encode(invitation()), packet.address, packet.port);
      }
    });
    return socket;
  }

  Future<List<String>> find({int rounds = 3}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final found = <String>{};
    socket.broadcastEnabled = true;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final packet = socket.receive();
      if (packet == null) return;
      try {
        final invitation = utf8.decode(packet.data);
        parse(invitation);
        if (found.length < 30) found.add(invitation);
      } catch (_) {
        /* Ignore unrelated LAN packets. */
      }
    });
    try {
      for (var i = 0; i < rounds; i++) {
        socket.send(
          utf8.encode(probe),
          InternetAddress('255.255.255.255'),
          port,
        );
        socket.send(utf8.encode(probe), InternetAddress.loopbackIPv4, port);
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      return found.toList();
    } finally {
      socket.close();
    }
  }
}

class PairingDiscovery {
  static const port = 42428;
  static const probe = 'ournet-pairing-discovery-1';
  static final _beacon = _Beacon(port, probe, PairingSession.parse);
  static Future<RawDatagramSocket> advertise(PairingSession session) =>
      _beacon.advertise(() => session.available, () => session.invitation);
  static Future<List<String>> find() => _beacon.find();
}

class FriendDiscovery {
  static const port = 42429;
  static const probe = 'ournet-friend-discovery-1';
  static final _beacon = _Beacon(port, probe, FriendSession.parse);
  static Future<RawDatagramSocket> advertise(FriendSession session) =>
      _beacon.advertise(() => session.available, () => session.invitation);
  static Future<List<String>> find({int rounds = 3}) =>
      _beacon.find(rounds: rounds);
}
