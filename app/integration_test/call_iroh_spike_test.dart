import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iroh_quic/iroh_quic.dart' as iroh;
import 'package:ournet/services/call_link.dart';

/// Spike for call media over iroh (docs/CONNECTIVITY.md, piece 6): two
/// WebRTC links whose real candidates are thrown away, so their only way to
/// each other is a local UDP shim per side whose packets travel as QUIC
/// datagrams on one iroh connection. Each side is given its own shim as the
/// other's host candidate.
///
/// Not shipped (October 2026, Windows): libwebrtc never sends to a loopback
/// candidate, so the planned loopback shim cannot work; a shim on the
/// device's own address connects, but was not tried with media, on Android or
/// across networks. Run by hand: `flutter test
/// integration_test/call_iroh_spike_test.dart -d windows`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<bool> spike(WidgetTester tester, InternetAddress candidateIp) async {
    await iroh.Iroh.init();
    const alpn = [0x73, 0x70, 0x69, 0x6b, 0x65];
    final ea = await iroh.Endpoint.bind(
      alpns: [alpn],
      relayMode: iroh.RelayMode.disabled,
    );
    final eb = await iroh.Endpoint.bind(
      alpns: [alpn],
      relayMode: iroh.RelayMode.disabled,
    );
    final accepted = eb.accept();
    final ca = await ea.connect(eb.addr, alpn);
    final cb = (await accepted)!;

    var tooLarge = 0, forwarded = 0, largest = 0;
    Future<RawDatagramSocket> shim(iroh.Connection conn) async {
      final socket = await RawDatagramSocket.bind(
        candidateIp.isLoopback ? candidateIp : InternetAddress.anyIPv4,
        0,
      );
      InternetAddress? peerHost;
      int? peerPort;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = socket.receive();
        if (d == null) return;
        // The first local WebRTC socket to send is the one answered.
        if (peerPort == null) {
          peerHost = d.address;
          peerPort = d.port;
        } else if (d.port != peerPort || d.address != peerHost) {
          return;
        }
        if (d.data.length > largest) largest = d.data.length;
        try {
          conn.sendDatagram(d.data);
          forwarded++;
        } catch (_) {
          tooLarge++;
        }
      });
      unawaited(() async {
        while (true) {
          final List<int> data;
          try {
            data = await conn.readDatagram();
          } catch (_) {
            return;
          }
          if (peerPort != null) socket.send(data, peerHost!, peerPort!);
        }
      }());
      return socket;
    }

    final sa = await shim(ca), sb = await shim(cb);
    final a = await WebRtcLink.create(device: 'a', iceServers: const []);
    final b = await WebRtcLink.create(device: 'b', iceServers: const []);
    addTearDown(() async {
      await a.close();
      await b.close();
      sa.close();
      sb.close();
      ca.close();
      cb.close();
      await ea.close();
      await eb.close();
    });
    // Real candidates are dropped: the shims are the only route.
    a.onCandidates = (_) {};
    b.onCandidates = (_) {};
    final answer = await b.accept(await a.createOffer());
    await a.acceptAnswer(answer);
    Map<String, Object?> host(int port) => {
      'candidate':
          'candidate:9 1 udp 1 ${candidateIp.address} $port typ host',
      'sdpMid': '0',
      'sdpMLineIndex': 0,
    };
    await a.addCandidates([host(sa.port)]);
    await b.addCandidates([host(sb.port)]);

    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline) &&
        (a.state != LinkState.connected || b.state != LinkState.connected)) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    // ignore: avoid_print
    print(
      'SPIKE ${candidateIp.address}: ${a.state}/${b.state}, '
      'forwarded $forwarded, too large $tooLarge, largest $largest B',
    );
    return a.state == LinkState.connected && b.state == LinkState.connected;
  }

  testWidgets('libwebrtc ignores a loopback shim candidate', (tester) async {
    expect(await spike(tester, InternetAddress.loopbackIPv4), isFalse);
  });

  testWidgets('a shim on this device\'s own address carries the link', (
    tester,
  ) async {
    final own = (await NetworkInterface.list(type: InternetAddressType.IPv4))
        .expand((i) => i.addresses)
        .firstWhere((a) => !a.isLoopback && !a.isLinkLocal);
    expect(await spike(tester, own), isTrue);
  });
}
