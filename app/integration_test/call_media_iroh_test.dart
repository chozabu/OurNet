import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iroh_quic/iroh_quic.dart' as iroh;
import 'package:ournet/services/call_link.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// Call media over iroh (docs/CONNECTIVITY.md, piece 6): the native call
/// shims (vendor/iroh_mobile/rust/src/call_media.rs) carry packets between
/// two endpoints in this process, and two WebRTC links whose real candidates
/// are thrown away connect through them alone, with audio when there is a
/// microphone. Each side is given its own shim as the other's candidate,
/// as `Calls` does.
///
/// Needs OurNet's iroh library (`tool/build-iroh.ps1`). Run by hand:
/// `flutter test integration_test/call_media_iroh_test.dart -d windows`.
/// Earlier, with a shim in Dart, this showed libwebrtc never sends to a
/// loopback candidate, which is why shims bind to the device's own address.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late iroh.Endpoint ea, eb;
  late iroh.Connection ca, cb;
  late CallMediaNative native;
  late InternetAddress own;

  setUp(() async {
    await iroh.Iroh.init();
    final loaded = CallMediaNative.load();
    expect(loaded, isNotNull, reason: 'run tool/build-iroh.ps1 first');
    native = loaded!;
    own = (await CallMediaNative.ownAddress())!;
    const alpn = [0x73, 0x70, 0x69, 0x6b, 0x65];
    ea = await iroh.Endpoint.bind(
      alpns: [alpn],
      relayMode: iroh.RelayMode.disabled,
    );
    eb = await iroh.Endpoint.bind(
      alpns: [alpn],
      relayMode: iroh.RelayMode.disabled,
    );
    final accepted = eb.accept();
    // The call's signalling connection, as in the app.
    ca = await ea.connect(eb.addr, alpn);
    cb = (await accepted)!;
    // Media connections are taken by the library inside accept.
    unawaited(() async {
      while (await ea.accept().catchError((Object _) => null) != null) {}
    }());
    unawaited(() async {
      while (await eb.accept().catchError((Object _) => null) != null) {}
    }());
  });

  tearDown(() async {
    native.stop(ea.id.asBytes(), eb.id.asBytes());
    native.stop(eb.id.asBytes(), ea.id.asBytes());
    ca.close();
    cb.close();
    await ea.close();
    await eb.close();
  });

  Future<void> until(
    WidgetTester tester,
    bool Function() done, {
    Duration within = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(within);
    while (!done() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
  }

  void report(String what) {
    // ignore: avoid_print
    print(
      'CALL MEDIA $what: A ${native.stats(ea.id.asBytes())}\n'
      '  B ${native.stats(eb.id.asBytes())}',
    );
  }

  testWidgets('shims carry RTP-sized packets both ways', (tester) async {
    final shimA = native.start(ea.id.asBytes(), eb.id.asBytes(), own)!;
    final shimB = native.start(eb.id.asBytes(), ea.id.asBytes(), own)!;
    late RawDatagramSocket wa, wb;
    await tester.runAsync(() async {
      wa = await RawDatagramSocket.bind(own, 0);
      wb = await RawDatagramSocket.bind(own, 0);
    });
    addTearDown(() {
      wa.close();
      wb.close();
    });
    final atA = <int>[], atB = <int>[];
    wa.listen((e) {
      if (e == RawSocketEvent.read) atA.add(wa.receive()?.data.length ?? 0);
    });
    wb.listen((e) {
      if (e == RawSocketEvent.read) atB.add(wb.receive()?.data.length ?? 0);
    });
    // Audio RTP is small; video and DTLS reach about 1,200 bytes, more than
    // a relay path's datagram.
    final sizes = [160, 1200, 1400];
    await until(tester, () {
      for (final n in sizes) {
        wa.send(Uint8List(n), own, shimA);
        wb.send(Uint8List(n), own, shimB);
      }
      return sizes.every(atA.contains) && sizes.every(atB.contains);
    });
    report('packets');
    expect(atB.toSet().containsAll(sizes), isTrue);
    expect(atA.toSet().containsAll(sizes), isTrue);
  });

  testWidgets('WebRTC connects through the shims alone', (tester) async {
    MediaStream? mic;
    await tester.runAsync(() async {
      try {
        mic = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
      } catch (_) {
        // No microphone here: the link is still checked, without audio.
      }
    });
    final audio = mic?.getAudioTracks().firstOrNull;
    final a = await WebRtcLink.create(
      device: 'a',
      iceServers: const [],
      audio: audio,
    );
    final b = await WebRtcLink.create(
      device: 'b',
      iceServers: const [],
      audio: audio,
    );
    addTearDown(() async {
      await a.close();
      await b.close();
      await mic?.dispose();
    });
    // Real candidates are dropped: the shims are the only route.
    a.onCandidates = (_) {};
    b.onCandidates = (_) {};
    final answer = await b.accept(await a.createOffer());
    await a.acceptAnswer(answer);
    final shimA = native.start(ea.id.asBytes(), eb.id.asBytes(), own)!;
    final shimB = native.start(eb.id.asBytes(), ea.id.asBytes(), own)!;
    Map<String, Object?> candidate(int port) => {
      'candidate': CallShim(own, port).candidate,
      'sdpMid': '0',
      'sdpMLineIndex': 0,
    };
    await a.addCandidates([candidate(shimA)]);
    await b.addCandidates([candidate(shimB)]);

    await until(
      tester,
      () => a.state == LinkState.connected && b.state == LinkState.connected,
    );
    report('link ${a.state}/${b.state}');
    expect(a.state, LinkState.connected);
    expect(b.state, LinkState.connected);
    if (audio == null) {
      markTestSkipped('No microphone: audio was not checked');
      return;
    }
    int received() =>
        (native.stats(eb.id.asBytes())?['receivedBytes'] as int? ?? 0);
    final before = received();
    await until(
      tester,
      () => received() > before + 20000,
      within: const Duration(seconds: 10),
    );
    report('audio');
    expect(received(), greaterThan(before + 20000));
  });
}
