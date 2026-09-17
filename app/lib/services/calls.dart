import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ournet_core/ournet_core.dart';
import 'network.dart';

/// Media uses WebRTC. Only signalling crosses the authenticated iroh link.
class Calls extends ChangeNotifier {
  final Network network;
  Calls(this.network) {
    network.signal = _signal;
  }
  RTCPeerConnection? _pc;
  MediaStream? _media;
  MediaStream? _remoteMedia;
  Future<void> _tracksReady = Future.value();
  final Set<String> _remoteTracks = {};
  List<MediaDeviceInfo> audioOutputs = [];
  List<MediaDeviceInfo> audioInputs = [];
  String? audioOutput;
  String? audioInput;
  bool speaker = false;
  bool video = false;
  String? peer;
  String phase = 'idle';
  String? error;
  Json? _offer;
  bool muted = false;
  final local = RTCVideoRenderer(), remote = RTCVideoRenderer();
  final List<RTCIceCandidate> _pending = [];
  bool _remoteReady = false;
  String? _session;
  bool _signallingReady = false;
  final List<RTCIceCandidate> _outgoing = [];
  Timer? _ringTimeout;
  bool _initialised = false;
  Future<void>? _initialising;
  Future<void>? _ending;
  int _generation = 0;
  Future<void> initialise() => _initialising ??= _initialise();

  Future<void> _initialise() async {
    await local.initialize();
    await remote.initialize();
    _initialised = true;
  }

  Future<void> _prepare(bool video) async {
    final generation = _generation;
    await initialise();
    if (generation != _generation) throw StateError('Call cancelled');
    _remoteReady = false;
    final pc = await createPeerConnection({
      'iceServers': network.node.store.setting('iceServers') ?? [],
    });
    if (generation != _generation) {
      await pc.close();
      await pc.dispose();
      throw StateError('Call cancelled');
    }
    _pc = pc;
    final received = await createLocalMediaStream('local');
    if (generation != _generation) {
      await received.dispose();
      throw StateError('Call cancelled');
    }
    _remoteMedia = received;
    _pc!.onIceCandidate = (candidate) {
      if (generation != _generation) return;
      if (peer != null && candidate.candidate != null) {
        if (!_signallingReady) {
          if (_outgoing.length < 64) _outgoing.add(candidate);
          return;
        }
        unawaited(
          network
              .request(peer!, {
                'type': 'signal',
                'payload': {
                  'type': 'ice',
                  'session': _session,
                  'candidate': candidate.toMap(),
                },
              })
              .catchError((Object e) {
                if (generation != _generation) return <String, dynamic>{};
                error = '$e';
                notifyListeners();
                return <String, dynamic>{};
              }),
        );
      }
    };
    _pc!.onTrack = (event) {
      if (generation != _generation) return;
      // Register received tracks in a native stream of our own. Desktop's
      // Unified Plan onTrack stream is not always in the renderer's registry.
      // This also handles streamless tracks and audio/video arriving separately.
      if (_remoteTracks.length >= 2 || !_remoteTracks.add(event.track.id!)) {
        return;
      }
      _tracksReady = _tracksReady
          .then((_) async {
            if (generation != _generation) return;
            await received.addTrack(event.track);
            if (generation != _generation) return;
            remote.srcObject = received;
            notifyListeners();
          })
          .catchError((Object e) {
            if (generation != _generation) return;
            error = 'Could not attach remote media: $e';
            notifyListeners();
          });
    };
    _pc!.onConnectionState = (state) {
      if (generation != _generation) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        phase = 'connected';
      }
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        phase = 'failed';
        error = 'Media connection failed; check ICE server configuration';
      }
      notifyListeners();
    };
    final desktop =
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS;
    if (desktop) {
      try {
        final devices = await navigator.mediaDevices.enumerateDevices();
        if (generation != _generation) throw StateError('Call cancelled');
        audioInputs = devices.where((d) => d.kind == 'audioinput').toList();
        audioOutputs = devices.where((d) => d.kind == 'audiooutput').toList();
        final savedInput = network.node.store.setting('callAudioInput');
        final savedOutput = network.node.store.setting('callAudioOutput');
        audioInput = audioInputs.any((d) => d.deviceId == savedInput)
            ? savedInput as String
            : null;
        audioOutput = audioOutputs.any((d) => d.deviceId == savedOutput)
            ? savedOutput as String
            : null;
      } catch (e) {
        if (generation == _generation) error = 'Audio devices: $e';
      }
    }
    if (generation != _generation) throw StateError('Call cancelled');
    final media = await navigator.mediaDevices.getUserMedia({
      'audio': audioInput == null
          ? true
          : {
              // Desktop flutter_webrtc uses sourceId for capture (deviceId routes
              // playback in its native audio constraints).
              'optional': [
                {'sourceId': audioInput},
              ],
            },
      'video': video,
    });
    if (generation != _generation) {
      for (final track in media.getTracks()) {
        await track.stop();
      }
      await media.dispose();
      throw StateError('Call cancelled');
    }
    _media = media;
    if (desktop && audioInput == null && media.getAudioTracks().isNotEmpty) {
      final actual = media.getAudioTracks().first.getSettings()['deviceId'];
      if (audioInputs.any((d) => d.deviceId == actual))
        audioInput = actual as String;
    }
    local.srcObject = _media;
    for (final track in _media!.getTracks()) {
      if (generation != _generation) throw StateError('Call cancelled');
      await pc.addTrack(track, media);
    }
    if (generation != _generation) throw StateError('Call cancelled');
    try {
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        speaker = video || (peer != null && isOwnDevice(peer!));
        if (speaker) {
          await Helper.setSpeakerphoneOnButPreferBluetooth();
        } else {
          await Helper.setSpeakerphoneOn(false);
        }
      } else if (audioOutput != null) {
        await Helper.selectAudioOutput(audioOutput!);
      }
    } catch (e) {
      if (generation == _generation) error = 'Audio routing: $e';
    }
    if (generation == _generation) notifyListeners();
  }

  bool isOwnDevice(String device) =>
      device != network.node.identity.device &&
      network.node.allowedPeer(device) &&
      network.node.contacts[device]?.person == network.node.person;

  Future<void> selectAudioOutput(String device) async {
    final generation = _generation;
    await Helper.selectAudioOutput(device);
    if (generation != _generation) return;
    audioOutput = device;
    network.node.store.set('callAudioOutput', device);
    notifyListeners();
  }

  Future<void> selectAudioInput(String device) async {
    final generation = _generation;
    await Helper.selectAudioInput(device);
    if (generation != _generation) return;
    audioInput = device;
    network.node.store.set('callAudioInput', device);
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    await Helper.setSpeakerphoneOn(!speaker);
    speaker = !speaker;
    notifyListeners();
  }

  Future<void> call(String device, {bool video = false}) async {
    if (phase != 'idle') throw StateError('A call is already active');
    if (device == network.node.identity.device ||
        !network.node.allowedPeer(device)) {
      throw StateError('Device not admitted');
    }
    peer = device;
    this.video = video;
    _session = randomId();
    final session = _session;
    _signallingReady = false;
    phase = 'calling';
    error = null;
    notifyListeners();
    try {
      await _prepare(video);
      if (_session != session) return;
      final pc = _pc!;
      final offer = await pc.createOffer();
      if (_session != session) return;
      await pc.setLocalDescription(offer);
      if (_session != session) return;
      await network.request(device, {
        'type': 'signal',
        'payload': {
          'type': 'offer',
          'session': _session,
          'sdp': offer.sdp,
          'video': video,
        },
      });
      if (_session != session) return;
      await _flushOutgoing();
      if (_session != session) return;
      _ringTimeout = Timer(const Duration(seconds: 60), () {
        if (_session == session && phase == 'calling') unawaited(hangup());
      });
    } catch (e) {
      if (_session == session) {
        await hangup();
        error = 'Call failed: $e';
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<Json> _signal(String device, Json message) async {
    if (!network.node.allowedPeer(device)) {
      throw StateError('Device not admitted');
    }
    if (message['session'] is! String ||
        (message['session'] as String).length > 64) {
      throw StateError('Invalid call session');
    }
    if (message['type'] != 'offer' &&
        (device != peer || message['session'] != _session)) {
      return {'ignored': true};
    }
    switch (message['type']) {
      case 'offer':
        if (phase != 'idle') throw StateError('Busy');
        peer = device;
        _session = message['session'];
        _signallingReady = false;
        _offer = message;
        video = message['video'] == true;
        phase = 'ringing';
        error = null;
        _ringTimeout = Timer(const Duration(seconds: 60), () {
          if (phase == 'ringing') unawaited(hangup());
        });
        if (isOwnDevice(device)) {
          // Do not make the offer acknowledgement wait for the answer request.
          unawaited(answer().catchError((Object _) {}));
        } else {
          notifyListeners();
        }
      case 'answer':
        _ringTimeout?.cancel();
        if (device != peer || _pc == null) {
          throw StateError('Unexpected answer');
        }
        final session = _session;
        await _pc!.setRemoteDescription(
          RTCSessionDescription(message['sdp'], 'answer'),
        );
        if (_session != session) return {'ignored': true};
        await _flush();
      case 'ice':
        if (device != peer) return {};
        final j = message['candidate'] as Json;
        final candidate = RTCIceCandidate(
          j['candidate'],
          j['sdpMid'],
          j['sdpMLineIndex'],
        );
        if (_remoteReady && _pc != null) {
          await _pc!.addCandidate(candidate);
        } else if (_pending.length < 64) {
          _pending.add(candidate);
        }
      case 'hangup':
        if (device == peer) await hangup(notifyPeer: false);
      default:
        throw StateError('Unknown call signal');
    }
    return {'ok': true};
  }

  Future<void> _flush() async {
    final pc = _pc;
    final session = _session;
    if (pc == null) return;
    _remoteReady = true;
    final candidates = _pending.toList();
    _pending.clear();
    for (final candidate in candidates) {
      if (_session != session) return;
      await pc.addCandidate(candidate);
    }
  }

  Future<void> _flushOutgoing() async {
    final session = _session;
    final device = peer;
    if (device == null) return;
    _signallingReady = true;
    final candidates = _outgoing.toList();
    _outgoing.clear();
    for (final candidate in candidates) {
      if (_session != session) return;
      await network.request(device, {
        'type': 'signal',
        'payload': {
          'type': 'ice',
          'session': session,
          'candidate': candidate.toMap(),
        },
      });
    }
  }

  Future<void> answer() async {
    if (_offer == null || peer == null || phase != 'ringing') return;
    final session = _session;
    final offer = _offer!;
    phase = 'connecting';
    notifyListeners();
    _ringTimeout?.cancel();
    try {
      await _prepare(offer['video'] == true);
      if (_session != session) return;
      final pc = _pc!;
      await pc.setRemoteDescription(
        RTCSessionDescription(offer['sdp'], 'offer'),
      );
      if (_session != session) return;
      await _flush();
      if (_session != session) return;
      final answer = await pc.createAnswer();
      if (_session != session) return;
      await pc.setLocalDescription(answer);
      if (_session != session) return;
      await network.request(peer!, {
        'type': 'signal',
        'payload': {'type': 'answer', 'session': _session, 'sdp': answer.sdp},
      });
      if (_session != session) return;
      await _flushOutgoing();
      notifyListeners();
    } catch (e) {
      if (_session == session) {
        await hangup();
        error = 'Could not answer call: $e';
        notifyListeners();
      }
      rethrow;
    }
  }

  void mute() {
    muted = !muted;
    for (final track in _media?.getAudioTracks() ?? []) {
      track.enabled = !muted;
    }
    notifyListeners();
  }

  Future<void> hangup({bool notifyPeer = true}) => _ending ??= _hangup(
    notifyPeer: notifyPeer,
  ).whenComplete(() => _ending = null);

  Future<void> _hangup({required bool notifyPeer}) async {
    error = null;
    _generation++;
    _ringTimeout?.cancel();
    _outgoing.clear();
    _signallingReady = false;
    final old = peer;
    final session = _session;
    _session = null;
    peer = null;
    phase = 'ending';
    notifyListeners();
    if (notifyPeer && old != null) {
      unawaited(
        network
            .request(old, {
              'type': 'signal',
              'payload': {'type': 'hangup', 'session': session},
            })
            .catchError((Object _) => <String, dynamic>{}),
      );
    }
    if (_initialised) {
      local.srcObject = null;
      remote.srcObject = null;
    }
    await _tracksReady;
    await _remoteMedia?.dispose();
    _remoteMedia = null;
    _remoteTracks.clear();
    for (final track in _media?.getTracks() ?? []) {
      await track.stop();
    }
    await _media?.dispose();
    _media = null;
    await _pc?.close();
    await _pc?.dispose();
    _pc = null;
    _pending.clear();
    _offer = null;
    muted = false;
    audioOutputs = [];
    audioInputs = [];
    audioOutput = null;
    audioInput = null;
    video = false;
    phase = 'idle';
    notifyListeners();
  }

  Future<void> close() async {
    network.signal = null;
    await hangup(notifyPeer: false);
    await _initialising;
    if (_initialised) {
      await local.dispose();
      await remote.dispose();
    }
    dispose();
  }
}
