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
  int _generation = 0;
  Future<void> initialise() async {
    await local.initialize();
    await remote.initialize();
    _initialised = true;
  }

  Future<void> _prepare(bool video) async {
    final generation = _generation;
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
                error = '$e';
                notifyListeners();
                return <String, dynamic>{};
              }),
        );
      }
    };
    _pc!.onTrack = (event) {
      if (generation != _generation) return;
      if (event.streams.isNotEmpty) remote.srcObject = event.streams.first;
      notifyListeners();
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
    final media = await navigator.mediaDevices.getUserMedia({
      'audio': true,
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
    local.srcObject = _media;
    for (final track in _media!.getTracks()) {
      await _pc!.addTrack(track, _media!);
    }
  }

  Future<void> call(String device, {bool video = false}) async {
    if (phase != 'idle') throw StateError('A call is already active');
    peer = device;
    _session = randomId();
    final session = _session;
    _signallingReady = false;
    phase = 'calling';
    error = null;
    notifyListeners();
    try {
      await _prepare(video);
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
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
      _ringTimeout = Timer(const Duration(seconds: 60), () {
        if (phase == 'calling') unawaited(hangup());
      });
    } catch (e) {
      if (_session == session) await hangup();
      rethrow;
    }
  }

  Future<Json> _signal(String device, Json message) async {
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
        phase = 'ringing';
        error = null;
        notifyListeners();
        _ringTimeout = Timer(const Duration(seconds: 60), () {
          if (phase == 'ringing') unawaited(hangup());
        });
      case 'answer':
        _ringTimeout?.cancel();
        if (device != peer || _pc == null) {
          throw StateError('Unexpected answer');
        }
        await _pc!.setRemoteDescription(
          RTCSessionDescription(message['sdp'], 'answer'),
        );
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
    _remoteReady = true;
    for (final candidate in _pending) {
      await _pc!.addCandidate(candidate);
    }
    _pending.clear();
  }

  Future<void> _flushOutgoing() async {
    _signallingReady = true;
    for (final candidate in _outgoing.toList()) {
      if (peer == null) break;
      await network.request(peer!, {
        'type': 'signal',
        'payload': {
          'type': 'ice',
          'session': _session,
          'candidate': candidate.toMap(),
        },
      });
    }
    _outgoing.clear();
  }

  Future<void> answer() async {
    if (_offer == null || peer == null) return;
    final session = _session;
    _ringTimeout?.cancel();
    try {
      await _prepare(_offer!['video'] == true);
      await _pc!.setRemoteDescription(
        RTCSessionDescription(_offer!['sdp'], 'offer'),
      );
      await _flush();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      if (_session != session) return;
      await network.request(peer!, {
        'type': 'signal',
        'payload': {'type': 'answer', 'session': _session, 'sdp': answer.sdp},
      });
      await _flushOutgoing();
      phase = 'connecting';
      notifyListeners();
    } catch (e) {
      if (_session == session) await hangup();
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

  Future<void> hangup({bool notifyPeer = true}) async {
    _generation++;
    _ringTimeout?.cancel();
    _outgoing.clear();
    _signallingReady = false;
    final old = peer;
    final session = _session;
    _session = null;
    peer = null;
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
    for (final track in _media?.getTracks() ?? []) {
      await track.stop();
    }
    await _media?.dispose();
    _media = null;
    await _pc?.close();
    await _pc?.dispose();
    _pc = null;
    local.srcObject = null;
    remote.srcObject = null;
    _pending.clear();
    _offer = null;
    muted = false;
    phase = 'idle';
    notifyListeners();
  }

  Future<void> close() async {
    network.signal = null;
    await hangup(notifyPeer: false);
    if (_initialised) {
      await local.dispose();
      await remote.dispose();
    }
    dispose();
  }
}
