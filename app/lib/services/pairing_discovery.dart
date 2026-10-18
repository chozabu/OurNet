import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:ournet_transport/ournet_transport.dart';

const _device = MethodChannel('ournet/device');
var _lanHolders = 0;

/// Keeps Android's Wi-Fi from filtering out broadcasts while any beacon is
/// open; most drivers drop them otherwise.
Future<void Function()> _holdLan() async {
  if (!Platform.isAndroid) return () {};
  if (_lanHolders++ == 0) {
    await _device.invokeMethod<void>('lanDiscovery', true).catchError((_) {});
  }
  var released = false;
  return () {
    if (released) return;
    released = true;
    if (--_lanHolders == 0) {
      unawaited(
        _device.invokeMethod<void>('lanDiscovery', false).catchError((_) {}),
      );
    }
  };
}

/// Where to send a probe: the limited broadcast and loopback, plus each
/// interface's /24 broadcast. Windows sends 255.255.255.255 out of one
/// adapter only, often a virtual one (Hyper-V, WSL, VirtualBox), so the
/// directed ones are what reach the Wi-Fi.
Future<List<InternetAddress>> _targets() async {
  final targets = <String>{'255.255.255.255', '127.0.0.1'};
  try {
    for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final a in i.addresses) {
        if (a.isLoopback || a.isLinkLocal) continue;
        final parts = a.address.split('.');
        if (parts.length == 4) targets.add('${parts.take(3).join('.')}.255');
      }
    }
  } catch (_) {
    /* Interfaces unavailable: the limited broadcast still goes out. */
  }
  return [for (final t in targets) InternetAddress(t)];
}

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
    final release = await _holdLan();
    socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final packet = socket.receive();
        if (packet != null &&
            available() &&
            utf8.decode(packet.data, allowMalformed: true) == probe) {
          socket.send(utf8.encode(invitation()), packet.address, packet.port);
        }
      },
      onDone: release,
      onError: (_) => release(),
    );
    return socket;
  }

  Future<List<String>> find({int rounds = 3}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final release = await _holdLan();
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
      final targets = await _targets();
      for (var i = 0; i < rounds; i++) {
        for (final target in targets) {
          try {
            socket.send(utf8.encode(probe), target, port);
          } catch (_) {
            /* An unreachable subnet must not stop the others. */
          }
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      return found.toList();
    } finally {
      socket.close();
      release();
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
