import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/services/noise_suppression.dart';
import 'package:ournet_core/ournet_core.dart';

/// The denoiser must sit in the real capture path: with it on, microphone
/// audio sent over a local peer connection goes through it. Needs a
/// microphone (Windows or Android).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('call audio passes through the denoiser', (tester) async {
    expect(CallNoiseSuppression.supported, isTrue);
    final store = Store();
    await CallNoiseSuppression.set(store, true);
    await CallNoiseSuppression.prepare();
    final mic = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    final a = await createPeerConnection({'iceServers': []});
    final b = await createPeerConnection({'iceServers': []});
    a.onIceCandidate = (c) => unawaited(b.addCandidate(c));
    b.onIceCandidate = (c) => unawaited(a.addCandidate(c));
    for (final track in mic.getAudioTracks()) {
      await a.addTrack(track, mic);
    }
    final offer = await a.createOffer();
    await a.setLocalDescription(offer);
    await b.setRemoteDescription(offer);
    final answer = await b.createAnswer();
    await b.setLocalDescription(answer);
    await a.setRemoteDescription(answer);

    final before = NoiseSuppression.frames;
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (NoiseSuppression.frames - before < 100 &&
        DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
    }
    final denoised = NoiseSuppression.frames - before;
    debugPrint('denoised $denoised frames, last ${NoiseSuppression.lastFrame}');

    // Off: frames still flow but are left alone.
    await CallNoiseSuppression.set(store, false);
    final off = NoiseSuppression.frames;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    final whileOff = NoiseSuppression.frames - off;

    for (final track in mic.getTracks()) {
      await track.stop();
    }
    await mic.dispose();
    await a.close();
    await b.close();
    expect(denoised, greaterThanOrEqualTo(100));
    expect(whileOff, 0);
  });
}
