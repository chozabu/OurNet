import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ournet_transport/ournet_transport.dart';

class PairingDiscovery {
  static const port = 42428;
  static const probe = 'ournet-pairing-discovery-1';
  static Future<RawDatagramSocket> advertise(PairingSession session) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final packet = socket.receive();
      if (packet != null &&
          session.available &&
          utf8.decode(packet.data, allowMalformed: true) == probe) {
        socket.send(
          utf8.encode(session.invitation),
          packet.address,
          packet.port,
        );
      }
    });
    return socket;
  }

  static Future<List<String>> find() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final found = <String>{};
    socket.broadcastEnabled = true;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final packet = socket.receive();
      if (packet == null) return;
      try {
        final invitation = utf8.decode(packet.data);
        PairingSession.parse(invitation);
        if (found.length < 30) found.add(invitation);
      } catch (_) {
        /* Ignore unrelated LAN packets. */
      }
    });
    try {
      for (var i = 0; i < 3; i++) {
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
