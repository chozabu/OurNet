import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/services/calls.dart';
import 'package:ournet/services/network.dart';
import 'package:ournet_core/ournet_core.dart';

/// Local native WebRTC loopback: temporary identities, one camera/microphone,
/// no signalling server or personal profile. Run in profile mode on hardware.
class LoopbackNetwork extends Network {
  LoopbackNetwork(super.node);
  late Future<Json> Function(Json) exchange;

  @override
  Future<Json> request(String device, Json message) =>
      exchange(message['payload'] as Json);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('native call renders remote video and transports audio both ways', (
    tester,
  ) async {
    final node = Node(await LocalIdentity.create(), Store());
    final other = await LocalIdentity.create();
    await node.addContact(other.certificate);
    final network = LoopbackNetwork(node);
    final calls = Calls(network);
    calls.addListener(
      () => debugPrint(
        'call: ${calls.phase}, remote tracks: '
        '${calls.remote.srcObject?.getTracks().length}, error: ${calls.error}',
      ),
    );
    final peer = await createPeerConnection({'iceServers': []});
    const session = 'native-test';
    MediaStream? capture;
    final pending = <RTCIceCandidate>[];
    final signalErrors = <Object>[];
    var remoteReady = false;
    peer.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      unawaited(
        network
            .signal!(other.device, {
              'type': 'ice',
              'session': session,
              'candidate': candidate.toMap(),
            })
            .catchError((Object e) {
              signalErrors.add(e);
              return <String, dynamic>{};
            }),
      );
    };
    network.exchange = (message) async {
      if (message['type'] == 'answer') {
        debugPrint('loopback: applying answer');
        await peer.setRemoteDescription(
          RTCSessionDescription(message['sdp'], 'answer'),
        );
        debugPrint('loopback: applied answer');
        remoteReady = true;
        for (final candidate in pending) {
          await peer.addCandidate(candidate);
        }
        pending.clear();
      } else if (message['type'] == 'ice') {
        final value = message['candidate'] as Json;
        final candidate = RTCIceCandidate(
          value['candidate'],
          value['sdpMid'],
          value['sdpMLineIndex'],
        );
        if (remoteReady) {
          await peer.addCandidate(candidate);
        } else {
          pending.add(candidate);
        }
      }
      return {'ok': true};
    };
    try {
      await calls.initialise();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Expanded(child: RTCVideoView(calls.local)),
                Expanded(child: RTCVideoView(calls.remote)),
              ],
            ),
          ),
        ),
      );
      const microphone = String.fromEnvironment('CALL_TEST_MICROPHONE');
      String? input;
      if (microphone.isNotEmpty) {
        final devices = await navigator.mediaDevices.enumerateDevices();
        input = devices
            .firstWhere(
              (d) => d.kind == 'audioinput' && d.label.contains(microphone),
            )
            .deviceId;
        node.store.set('callAudioInput', input);
      }
      capture = await navigator.mediaDevices.getUserMedia({
        'audio': input == null
            ? true
            : {
                'optional': [
                  {'sourceId': input},
                ],
              },
        'video': true,
      });
      for (final track in capture.getTracks()) {
        await peer.addTrack(track, capture);
      }
      final offer = await peer.createOffer();
      var receivedSdp = offer.sdp!;
      for (final track in capture.getTracks()) {
        receivedSdp = receivedSdp.replaceAll(track.id!, 'received-${track.id}');
      }
      // Receiving video without starting a second camera keeps this test
      // runnable on Android. Rename the offered track IDs to emulate separate
      // processes: otherwise native lookup can return the original capture
      // instead of the decoded receiver track, giving a false-positive render.
      await network.signal!(other.device, {
        'type': 'offer',
        'session': session,
        'sdp': receivedSdp,
        'video': false,
      });
      await peer.setLocalDescription(offer);
      await calls.answer();
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      List<StatsReport> stats = [];
      bool hasAudio(String direction) => stats.any(
        (s) =>
            s.type == '$direction-rtp' &&
            (s.values['kind'] == 'audio' || s.values['mediaType'] == 'audio') &&
            (num.tryParse(
                      '${s.values[direction == 'inbound' ? 'bytesReceived' : 'bytesSent']}',
                    ) ??
                    0) >
                0,
      );
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        stats = await peer.getStats();
        if (calls.phase == 'connected' &&
            calls.remote.videoWidth > 0 &&
            hasAudio('inbound') &&
            hasAudio('outbound')) {
          break;
        }
      }
      binding.reportData = {
        'phase': calls.phase,
        'error': calls.error,
        'remoteWidth': calls.remote.videoWidth,
        'remoteHeight': calls.remote.videoHeight,
        'audioInbound': hasAudio('inbound'),
        'audioOutbound': hasAudio('outbound'),
        'rtp': [
          for (final s in stats)
            if (s.type.endsWith('-rtp')) {'type': s.type, 'values': s.values},
        ],
      };
      expect(signalErrors, isEmpty);
      expect(calls.error, isNull);
      expect(calls.phase, 'connected');
      expect(calls.remote.videoWidth, greaterThan(0));
      expect(
        calls.remote.srcObject!.getVideoTracks().single.id,
        'received-${capture.getVideoTracks().single.id}',
      );
      expect(calls.remote.srcObject!.getAudioTracks(), hasLength(1));
      expect(
        hasAudio('inbound'),
        isTrue,
        reason: 'Audio must reach the other peer',
      );
      expect(hasAudio('outbound'), isTrue, reason: 'Audio must be sent back');
    } finally {
      peer.onIceCandidate = null;
      await tester.pumpWidget(const SizedBox());
      await calls.close();
      await peer.close();
      await peer.dispose();
      for (final track in capture?.getTracks() ?? <MediaStreamTrack>[]) {
        await track.stop();
      }
      await capture?.dispose();
      await node.close();
    }
  });
}
