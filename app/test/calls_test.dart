import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/calls.dart';
import 'package:ournet/services/network.dart';
import 'package:ournet/ui/call_screen.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart' show CallShim, PeerPath;

class CallNetwork extends Network {
  CallNetwork(super.node);
  final sent = <Json>[];
  final to = <String>[];
  final Set<String> unreachable = {};
  Future<void> Function(Json)? onRequest;
  Future<void> Function(String, Json)? onDeviceRequest;
  final shims = <String>[];
  final stopped = <String>[];
  var shimPort = 4000;

  @override
  Future<CallShim?> callMediaStart(String device) async {
    shims.add(device);
    return CallShim(InternetAddress('192.168.1.5'), shimPort++);
  }

  @override
  void callMediaStop(String device) => stopped.add(device);

  PeerPath? shimPath;
  @override
  PeerPath? callMediaPath(String device) => shimPath;

  @override
  Future<Json> request(String device, Json message) async {
    if (unreachable.contains(device)) throw StateError('unreachable');
    final payload = message['payload'] as Json;
    sent.add(payload);
    to.add(device);
    await onDeviceRequest?.call(device, payload);
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
  late LocalIdentity friendPhone;
  final methods = <MethodCall>[];
  final eventChannels = <String>[];
  var texture = 0;
  Completer<void>? captureGate;
  bool denyCapture = false;
  Object? stats;

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
    final phone = await LocalIdentity.create();
    friendPhone = await phone.enrol(await friend.authorise(phone.certificate));
    await node.addContact(friendPhone.certificate);
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
        case 'getStats':
          return stats;
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
    await signal(network, device, {
      'type': 'offer',
      'session': 'session',
      'sdp': 'offer-sdp',
      'video': video,
    });
  }

  test('ICE servers default to public STUN, except in local mode', () {
    expect(iceServers(null, local: false), defaultIceServers);
    expect(iceServers(null, local: true), isEmpty);
    // An explicit empty list keeps direct candidates only.
    expect(iceServers(<Object?>[], local: false), isEmpty);
    final own = [
      {'urls': 'turn:example.org', 'username': 'u', 'credential': 'c'},
    ];
    expect(iceServers(own, local: true), own);
  });

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

  test('each side offers its call shim as the lowest-priority candidate, '
      'again after a restart, and stops it with the call', () async {
    List<String> shimCandidates() => [
      for (final m in methods)
        if (m.method == 'addCandidate')
          (m.arguments['candidate'] as Map)['candidate'] as String,
    ].where((c) => c.contains('192.168.1.5')).toList();
    await offer(friend.device);
    await calls.answer();
    await pumpEventQueue();
    expect(network.shims, [friend.device]);
    expect(shimCandidates(), [
      'candidate:ournet 1 udp 1 192.168.1.5 4000 typ host',
    ]);
    // The caller's network changed: its new offer drops every candidate,
    // so the shim is rebound and offered again.
    await signal(network, friend.device, {
      'type': 'restart',
      'session': 'session',
      'sdp': 'restart-sdp',
    });
    await pumpEventQueue();
    expect(network.shims, [friend.device, friend.device]);
    expect(shimCandidates().last, contains('192.168.1.5 4001 typ host'));
    await calls.hangup();
    expect(network.stopped, [friend.device]);
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
    expect(
      methods
          .singleWhere((m) => m.method == 'getUserMedia')
          .arguments['constraints']['audio'],
      {
        'optional': [
          {'sourceId': 'physical-mic'},
        ],
      },
    );
    expect(methods.where((m) => m.method == 'selectAudioOutput'), hasLength(1));
    expect(calls.audioInput, 'physical-mic');
    expect(calls.audioOutput, 'speakers');
  });

  test(
    'missing saved audio devices fall back without breaking the call',
    () async {
      node.store.set('callAudioInput', 'unplugged');
      node.store.set('callAudioOutput', 'unplugged');
      await calls.call(friend.device);
      expect(calls.error, isNull);
      expect(calls.audioInput, isNull);
      expect(calls.audioOutput, isNull);
      expect(
        methods
            .singleWhere((m) => m.method == 'getUserMedia')
            .arguments['constraints']['audio'],
        true,
      );
    },
  );

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
      await signal(network, friend.device, {
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

  List<String> sentTo(String type) => [
    for (var i = 0; i < network.sent.length; i++)
      if (network.sent[i]['type'] == type) network.to[i],
  ];

  test('calling a person rings all their devices', () async {
    expect(calls.devicesOf(friend.person), hasLength(2));
    await calls.callPerson(friend.person);
    expect(
      sentTo('offer'),
      unorderedEquals([friend.device, friendPhone.device]),
    );
    expect(calls.phase, 'calling');
  });

  test('first device to answer takes the call; others stop ringing', () async {
    await calls.callPerson(friend.person);
    final session = network.sent.first['session'];
    await signal(network, friendPhone.device, {
      'type': 'answer',
      'session': session,
      'sdp': 'answer-sdp',
    });
    expect(calls.peer, friendPhone.device);
    expect(sentTo('hangup'), [friend.device]);
    await expectLater(
      signal(network, friend.device, {
        'type': 'answer',
        'session': session,
        'sdp': 'answer-sdp',
      }),
      completion({'ignored': true}),
    );
    await signal(network, friend.device, {
      'type': 'hangup',
      'session': session,
    });
    expect(calls.phase, isNot('idle'));
    await calls.hangup();
    expect(sentTo('hangup'), [friend.device, friendPhone.device]);
  });

  test('declining on one device ends the call on the others', () async {
    await calls.callPerson(friend.person);
    final session = network.sent.first['session'];
    await signal(network, friend.device, {
      'type': 'hangup',
      'session': session,
    });
    expect(calls.phase, 'idle');
    expect(sentTo('hangup'), [friendPhone.device]);
  });

  test('an unreachable device does not stop the others ringing', () async {
    network.unreachable.add(friend.device);
    await calls.callPerson(friend.person);
    expect(calls.phase, 'calling');
    expect(calls.peer, friendPhone.device);
    await calls.hangup();
  });

  test('a pending offer does not delay another device connecting', () async {
    final slow = Completer<void>();
    final offered = Completer<void>();
    network.onDeviceRequest = (device, payload) async {
      if (device == friend.device && payload['type'] == 'offer') {
        offered.complete();
        await slow.future;
      }
    };
    final calling = calls.callPerson(friend.person);
    try {
      await offered.future;
      await Future<void>.delayed(Duration.zero);
      expect(calls.rung, isTrue);
      expect(calls.peer, friendPhone.device);
      await event({
        'event': 'onCandidate',
        'candidate': {'candidate': 'c1', 'sdpMid': '0', 'sdpMLineIndex': 0},
      });
      expect(sentTo('ice'), [friendPhone.device]);
      final session = calls.session;
      await signal(network, friendPhone.device, {
        'type': 'answer',
        'session': session,
        'sdp': 'answer-sdp',
      });
      slow.complete();
      await calling;
      expect(calls.peer, friendPhone.device);
      expect(sentTo('ice'), [friendPhone.device]);
      expect(calls.phase, isNot('idle'));
    } finally {
      if (!slow.isCompleted) slow.complete();
      await calling;
    }
  });

  test(
    'an answer before offer acknowledgement releases queued candidates',
    () async {
      final gate = Completer<void>();
      final offered = Completer<void>();
      network.onDeviceRequest = (_, payload) async {
        if (payload['type'] == 'offer') {
          offered.complete();
          await gate.future;
        }
      };
      final calling = calls.call(friend.device);
      try {
        await offered.future;
        await event({
          'event': 'onCandidate',
          'candidate': {
            'candidate': 'early',
            'sdpMid': '0',
            'sdpMLineIndex': 0,
          },
        });
        expect(sentTo('ice'), isEmpty);
        await signal(network, friend.device, {
          'type': 'answer',
          'session': calls.session,
          'sdp': 'answer-sdp',
        });
        expect(sentTo('ice'), [friend.device]);
        gate.complete();
        await calling;
        expect(sentTo('ice'), [friend.device]);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await calling;
      }
    },
  );

  test('a later offer acknowledgement receives cached candidates', () async {
    final slow = Completer<void>();
    final offered = Completer<void>();
    network.onDeviceRequest = (device, payload) async {
      if (device == friend.device && payload['type'] == 'offer') {
        offered.complete();
        await slow.future;
      }
    };
    final calling = calls.callPerson(friend.person);
    try {
      await offered.future;
      await Future<void>.delayed(Duration.zero);
      await event({
        'event': 'onCandidate',
        'candidate': {'candidate': 'c1', 'sdpMid': '0', 'sdpMLineIndex': 0},
      });
      expect(sentTo('ice'), [friendPhone.device]);
      slow.complete();
      await calling;
      expect(
        sentTo('ice'),
        unorderedEquals([friendPhone.device, friend.device]),
      );
    } finally {
      if (!slow.isCompleted) slow.complete();
      await calling;
    }
  });

  test('a device that cannot be reached yet rings once it can', () async {
    calls.reachEvery = const Duration(milliseconds: 20);
    network.unreachable.add(friend.device);
    await calls.call(friend.device, video: true);
    // Still trying, but nothing is ringing yet.
    expect(calls.phase, 'calling');
    expect(calls.rung, isFalse);
    expect(sentTo('ice'), isEmpty);
    await event({
      'event': 'onCandidate',
      'candidate': {'candidate': 'c1', 'sdpMid': '0', 'sdpMLineIndex': 0},
    });
    expect(sentTo('ice'), isEmpty);

    // The phone wakes: the offer arrives, then what was found meanwhile.
    network.unreachable.clear();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(calls.rung, isTrue);
    expect(sentTo('offer'), [friend.device]);
    expect(sentTo('ice'), [friend.device]);
    final offers = sentTo('offer').length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(sentTo('offer'), hasLength(offers));
    await calls.hangup();
  });

  test('the caller gives up on a device it never reaches', () async {
    calls.reachEvery = const Duration(milliseconds: 20);
    calls.reachFor = const Duration(milliseconds: 100);
    network.unreachable.add(friend.device);
    await calls.call(friend.device);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(calls.phase, 'idle');
    expect(calls.error, contains('Could not reach'));
    // Nothing reached it, so there is nobody to tell.
    expect(sentTo('hangup'), isEmpty);
  });

  test(
    'a sleeping phone is woken to ring, and stops when the caller gives up',
    () async {
      final wakes = <String>[];
      calls.onWake = (device, kind, session) =>
          wakes.add('$kind $device $session');
      network.unreachable.add(friend.device);
      await calls.call(friend.device);
      final session = calls.session;
      expect(wakes, ['call ${friend.device} $session']);
      await calls.hangup();
      expect(wakes, [
        'call ${friend.device} $session',
        'cancel ${friend.device} $session',
      ]);
    },
  );

  test('only the devices that did not answer stop ringing', () async {
    final wakes = <String>[];
    calls.onWake = (device, kind, _) => wakes.add('$kind $device');
    await calls.callPerson(friend.person);
    expect(wakes, hasLength(2));
    await signal(network, friend.device, {
      'type': 'answer',
      'session': network.sent.first['session'],
      'sdp': 'answer-sdp',
    });
    expect(wakes.where((w) => w.startsWith('cancel')), [
      'cancel ${friendPhone.device}',
    ]);
    await calls.hangup();
    expect(wakes, hasLength(3));
  });

  test('a busy device is not offered the call again', () async {
    calls.reachEvery = const Duration(milliseconds: 20);
    network.onRequest = (payload) async {
      if (payload['type'] == 'offer') throw StateError('Busy');
    };
    await expectLater(calls.call(friend.device), throwsStateError);
    expect(calls.phase, 'idle');
    expect(calls.error, contains('Busy'));
  });

  group('call history', () {
    final records = <CallRecord>[];
    setUp(() {
      records.clear();
      calls.onRecord = records.add;
    });

    test('an answered call records how long it lasted', () async {
      await calls.call(friend.device, video: true);
      await signal(network, friend.device, {
        'type': 'answer',
        'session': network.sent.first['session'],
        'sdp': 'answer-sdp',
      });
      await event({'event': 'peerConnectionState', 'state': 'connected'});
      await calls.hangup();
      expect(records.single.person, friend.person);
      expect(records.single.video, isTrue);
      expect(records.single.outcome, 'answered');
    });

    test('the route media took is shown live and recorded', () async {
      calls.routeEvery = const Duration(milliseconds: 10);
      Json report(String id, String type, Json values) => {
        'id': id,
        'type': type,
        'timestamp': 0,
        'values': values,
      };
      // Media goes through the call shim, whose connection is relayed.
      stats = {
        'stats': [
          report('T', 'transport', {'selectedCandidatePairId': 'P'}),
          report('P', 'candidate-pair', {
            'localCandidateId': 'L',
            'remoteCandidateId': 'R',
          }),
          report('L', 'local-candidate', {
            'candidateType': 'host',
            'ip': '192.168.1.5',
            'port': 5000,
          }),
          report('R', 'remote-candidate', {
            'candidateType': 'host',
            'ip': '192.168.1.5',
            'port': 4000,
          }),
        ],
      };
      network.shimPath = PeerPath.parse(
        'Relay(https://euc1-1.relay.n0.iroh.link./)',
        DateTime(2026),
      );
      await calls.call(friend.device);
      await signal(network, friend.device, {
        'type': 'answer',
        'session': network.sent.first['session'],
        'sdp': 'answer-sdp',
      });
      await pumpEventQueue();
      await event({'event': 'peerConnectionState', 'state': 'connected'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls.route?.label, 'Via relay');
      expect(calls.route?.overIroh, isTrue);
      await calls.hangup();
      expect(calls.route, isNull);
      expect(records.single.route, 'relay');
    });

    test('a call nobody answered is missed', () async {
      await calls.callPerson(friend.person);
      await calls.hangup();
      expect(records.single.outcome, 'missed');
    });

    test('a call turned down is declined', () async {
      await calls.callPerson(friend.person);
      await signal(network, friendPhone.device, {
        'type': 'hangup',
        'session': network.sent.first['session'],
      });
      expect(records.single.outcome, 'declined');
    });

    test('only the caller records; own devices are not recorded', () async {
      await offer(friend.device);
      await calls.hangup();
      await calls.call(own.device);
      await calls.hangup();
      expect(records, isEmpty);
    });
  });

  test(
    'each side tells the other when it mutes or pauses its camera',
    () async {
      await calls.call(friend.device, video: true);
      final session = network.sent.first['session'];
      await signal(network, friend.device, {
        'type': 'answer',
        'session': session,
        'sdp': 'answer-sdp',
      });
      calls.mute();
      calls.toggleCamera();
      await pumpEventQueue();
      final states = network.sent.where((m) => m['type'] == 'state').toList();
      expect(states.last, containsPair('muted', true));
      expect(states.last, containsPair('camera', false));

      await signal(network, friend.device, {
        'type': 'state',
        'session': session,
        'muted': true,
        'camera': false,
      });
      expect(calls.remoteMuted, isTrue);
      expect(calls.remoteCameraOff, isTrue);
      // Another device cannot speak for the peer.
      await signal(network, friendPhone.device, {
        'type': 'state',
        'session': session,
        'muted': false,
      });
      expect(calls.remoteMuted, isTrue);
      await calls.hangup();
      expect(calls.remoteMuted, isFalse);
    },
  );

  test('the caller knows once the call is ringing elsewhere', () async {
    expect(calls.rung, isFalse);
    await calls.call(friend.device);
    expect(calls.rung, isTrue);
    await calls.hangup();
    expect(calls.rung, isFalse);
  });

  test('the camera pauses and resumes without renegotiating', () async {
    await calls.call(friend.device, video: true);
    final offers = network.sent.where((m) => m['type'] == 'offer').length;
    calls.toggleCamera();
    expect(calls.cameraOff, isTrue);
    await pumpEventQueue();
    expect(
      methods
          .lastWhere((m) => m.method == 'mediaStreamTrackSetEnable')
          .arguments,
      containsPair('enabled', false),
    );
    calls.toggleCamera();
    expect(calls.cameraOff, isFalse);
    expect(network.sent.where((m) => m['type'] == 'offer'), hasLength(offers));
    calls.toggleCamera();
    await calls.hangup();
    // The next call starts with the camera on.
    expect(calls.cameraOff, isFalse);
  });

  testWidgets('an incoming call shows who and can be declined', (tester) async {
    await offer(friend.device, video: true);
    var opened = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CallScreen(
                      calls: calls,
                      name: 'Sam',
                      act: (action) => action(),
                    ),
                  ),
                );
                opened = false;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Incoming video call'), findsOneWidget);
    expect(find.byTooltip('Answer'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Decline'));
      await pumpEventQueue(times: 50);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls.phase, 'idle');
    expect(network.sent.last['type'], 'hangup');
    // The call ended, so the screen closed itself.
    expect(opened, isFalse);
    // Set by setUp for the call service; the widget test must leave it unset.
    debugDefaultTargetPlatformOverride = null;
  });
}

/// Delivers a call message to [network] as a peer's `signal` request would.
Future<Json> signal(Network network, String device, Json payload) => network
    .node
    .registry
    .handler('signal')!(device, {'type': 'signal', 'payload': payload});
