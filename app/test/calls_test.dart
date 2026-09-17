import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/calls.dart';
import 'package:ournet/services/network.dart';
import 'package:ournet_core/ournet_core.dart';

class CallNetwork extends Network {
  CallNetwork(super.node);
  final sent = <Json>[];
  Future<void> Function(Json)? onRequest;

  @override
  Future<Json> request(String device, Json message) async {
    final payload = message['payload'] as Json;
    sent.add(payload);
    await onRequest?.call(payload);
    return {'ok': true};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Node node;
  late CallNetwork network;
  late Calls calls;
  late LocalIdentity own;
  late LocalIdentity friend;
  final methods = <MethodCall>[];
  final eventChannels = <String>[];
  var texture = 0;
  Completer<void>? captureGate;
  bool denyCapture = false;

  Json track(String kind) => {
    'id': 'remote-$kind',
    'label': kind,
    'kind': kind,
    'enabled': true,
  };
  Json parameters() => {
    'encodings': [],
    'headerExtensions': [],
    'codecs': [],
    'rtcp': {'reducedSize': true},
  };
  Future<void> event(Json value) async {
    await messenger.handlePlatformMessage(
      'FlutterWebRTC/peerConnectionEventpc',
      codec.encodeSuccessEnvelope(value),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    methods.clear();
    eventChannels.clear();
    texture = 0;
    captureGate = null;
    denyCapture = false;
    node = Node(await LocalIdentity.create(), Store());
    final fresh = await LocalIdentity.create();
    own = await fresh.enrol(await node.identity.authorise(fresh.certificate));
    friend = await LocalIdentity.create();
    await node.addContact(own.certificate);
    await node.addContact(friend.certificate);
    network = CallNetwork(node);
    calls = Calls(network);
    void registerEvents(String name) {
      eventChannels.add(name);
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }

    messenger.setMockMethodCallHandler(channel, (method) async {
      methods.add(method);
      switch (method.method) {
        case 'createVideoRenderer':
          registerEvents('FlutterWebRTC/Texture${++texture}');
          return {'textureId': texture};
        case 'createPeerConnection':
          registerEvents('FlutterWebRTC/peerConnectionEventpc');
          return {'peerConnectionId': 'pc'};
        case 'createLocalMediaStream':
          return {'streamId': 'received'};
        case 'getUserMedia':
          await captureGate?.future;
          if (denyCapture) throw PlatformException(code: 'permission-denied');
          return {
            'streamId': 'capture',
            'audioTracks': [
              {...track('audio'), 'id': 'microphone'},
            ],
            'videoTracks': [
              {...track('video'), 'id': 'camera'},
            ],
          };
        case 'addTrack':
          return {
            'senderId': 'sender',
            'track': {},
            'ownsTrack': false,
            'rtpParameters': parameters(),
          };
        case 'createOffer':
          return {'sdp': 'offer-sdp', 'type': 'offer'};
        case 'createAnswer':
          return {'sdp': 'answer-sdp', 'type': 'answer'};
        case 'getSources':
          return {
            'sources': [
              {
                'deviceId': 'physical-mic',
                'label': 'Microphone',
                'kind': 'audioinput',
                'groupId': '',
              },
              {
                'deviceId': 'speakers',
                'label': 'Speakers',
                'kind': 'audiooutput',
                'groupId': '',
              },
            ],
          };
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    await calls.close();
    await node.close();
    messenger.setMockMethodCallHandler(channel, null);
    for (final name in eventChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> offer(String device, {bool video = true}) async {
    await network.signal!(device, {
      'type': 'offer',
      'session': 'session',
      'sdp': 'offer-sdp',
      'video': video,
    });
  }

  test('answer cannot overwrite connected during signalling', () async {
    await offer(friend.device);
    network.onRequest = (payload) async {
      if (payload['type'] == 'answer') {
        await event({'event': 'peerConnectionState', 'state': 'connected'});
      }
    };
    await calls.answer();
    expect(calls.phase, 'connected');
    expect(calls.audioOutputs.single.label, 'Speakers');
    await calls.selectAudioOutput('speakers');
    expect(methods.last.method, 'selectAudioOutput');
  });

  test('video calls on mobile request speaker routing', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await calls.call(friend.device, video: true);
    expect(calls.speaker, isTrue);
    expect(
      methods.any((m) => m.method == 'enableSpeakerphoneButPreferBluetooth'),
      isTrue,
    );
    await calls.toggleSpeaker();
    expect(calls.speaker, isFalse);
  });

  test('answer pressed twice starts only one capture', () async {
    await offer(friend.device);
    final first = calls.answer();
    await calls.answer();
    await first;
    expect(methods.where((m) => m.method == 'getUserMedia'), hasLength(1));
    expect(network.sent.where((m) => m['type'] == 'answer'), hasLength(1));
  });

  test('microphone and output choices survive the next call', () async {
    await calls.call(friend.device);
    await calls.selectAudioInput('physical-mic');
    await calls.selectAudioOutput('speakers');
    await calls.hangup();
    methods.clear();
    await calls.call(friend.device);
    expect(methods.singleWhere((m) => m.method == 'getUserMedia')
        .arguments['constraints']['audio'], {
      'optional': [{'sourceId': 'physical-mic'}],
    });
    expect(methods.where((m) => m.method == 'selectAudioOutput'), hasLength(1));
    expect(calls.audioInput, 'physical-mic');
    expect(calls.audioOutput, 'speakers');
  });

  test('missing saved audio devices fall back without breaking the call', () async {
    node.store.set('callAudioInput', 'unplugged');
    node.store.set('callAudioOutput', 'unplugged');
    await calls.call(friend.device);
    expect(calls.error, isNull);
    expect(calls.audioInput, isNull);
    expect(calls.audioOutput, isNull);
    expect(methods.singleWhere((m) => m.method == 'getUserMedia')
        .arguments['constraints']['audio'], true);
  });

  test(
    'streamless and separate remote tracks use registered native stream',
    () async {
      await calls.call(friend.device, video: true);
      for (final kind in ['audio', 'video', 'video']) {
        await event({
          'event': 'onTrack',
          'streams': [],
          'track': track(kind),
          'receiver': {
            'receiverId': kind,
            'track': track(kind),
            'rtpParameters': parameters(),
          },
        });
      }
      expect(calls.remote.srcObject!.getTracks().length, 2);
      final added = methods.where((m) => m.method == 'mediaStreamAddTrack');
      expect(added.length, 2);
      expect(added.every((m) => m.arguments['streamId'] == 'received'), isTrue);
      expect(
        methods
            .where((m) => m.method == 'videoRendererSetSrcObject')
            .last
            .arguments['streamId'],
        'received',
      );
      await calls.hangup();
      expect(calls.remote.srcObject, isNull);
      expect(
        methods.any(
          (m) =>
              m.method == 'streamDispose' &&
              m.arguments['streamId'] == 'received',
        ),
        isTrue,
      );
    },
  );

  test(
    'own device auto-answers without blocking offer acknowledgement',
    () async {
      captureGate = Completer<void>();
      await offer(own.device, video: false);
      expect(calls.phase, 'connecting');
      final answered = Completer<void>();
      network.onRequest = (payload) async {
        if (payload['type'] == 'answer') answered.complete();
      };
      captureGate!.complete();
      await answered.future;
      await Future<void>.delayed(Duration.zero);
      expect(
        methods
            .singleWhere((m) => m.method == 'getUserMedia')
            .arguments['constraints']['video'],
        false,
      );
    },
  );

  test(
    'friend cannot request auto-answer; revoked own device is rejected',
    () async {
      await network.signal!(friend.device, {
        'type': 'offer',
        'session': 'session',
        'sdp': 'offer',
        'autoAnswer': true,
      });
      expect(calls.phase, 'ringing');
      expect(methods.where((m) => m.method == 'getUserMedia'), isEmpty);
      await calls.hangup();
      await node.revoke(own.device);
      expect(calls.isOwnDevice(own.device), false);
      await expectLater(offer(own.device), throwsStateError);
      expect(calls.phase, 'idle');
    },
  );

  test('busy own-device offer does not replace active call', () async {
    await offer(friend.device);
    await expectLater(offer(own.device), throwsStateError);
    expect(calls.peer, friend.device);
    expect(calls.phase, 'ringing');
  });

  test(
    'hangup while capturing releases late media and never sends answer',
    () async {
      captureGate = Completer<void>();
      await offer(friend.device);
      final answering = calls.answer();
      final failure = expectLater(answering, throwsStateError);
      while (!methods.any((m) => m.method == 'getUserMedia')) {
        await Future<void>.delayed(Duration.zero);
      }
      await calls.hangup();
      captureGate!.complete();
      await failure;
      expect(calls.phase, 'idle');
      expect(calls.local.srcObject, isNull);
      expect(network.sent.where((m) => m['type'] == 'answer'), isEmpty);
      expect(
        methods.any(
          (m) =>
              m.method == 'streamDispose' &&
              m.arguments['streamId'] == 'capture',
        ),
        isTrue,
      );
    },
  );

  test(
    'auto-answer capture failure is visible and releases the call',
    () async {
      denyCapture = true;
      await offer(own.device);
      while (calls.phase != 'idle') {
        await Future<void>.delayed(Duration.zero);
      }
      expect(calls.error, contains('Could not answer call'));
      expect(calls.peer, isNull);
    },
  );
}
