import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ournet_core/ournet_core.dart';
import 'calls.dart' show androidRemoteStreams;

/// How one media link to another device is doing.
enum LinkState { connecting, connected, reconnecting, failed, closed }

/// One WebRTC connection to one other device in a group call. A call is a mesh
/// of these; [GroupCalls] decides who connects to whom and carries the
/// signalling. Tracks are fixed at two transceivers (audio and video) when the
/// link is made, so turning the camera on or off is a track swap with no new
/// negotiation.
abstract class MediaLink {
  LinkState get state;

  /// Draws this device's video; null until the link has been made.
  RTCVideoRenderer? get renderer;

  /// This device's recent audio level, 0 to 1.
  double get level;

  /// Round trip time in milliseconds, and the share of packets lost since the
  /// last reading, when known.
  int? get rttMs;
  double get loss;

  void Function()? onChange;

  /// Candidates found since the last call, a burst at a time.
  void Function(List<Json> candidates)? onCandidates;

  /// An offer to send; [restart] replaces candidates on a link that was lost.
  Future<String> createOffer({bool restart = false});

  /// Takes the other side's offer and returns the answer.
  Future<String> accept(String offer);
  Future<void> acceptAnswer(String answer);
  Future<void> addCandidates(List<Json> candidates);

  /// What this device sends: the microphone and, when on, the camera.
  Future<void> setTracks({MediaStreamTrack? audio, MediaStreamTrack? video});

  /// Caps what the camera sends to this device, for a call with many people.
  Future<void> limitVideo({required int maxBitrate, required double scale});

  /// Reads quality and audio level.
  Future<void> poll();
  Future<void> close();
}

/// This device's microphone and camera, shared by every link.
abstract class LocalMedia {
  MediaStreamTrack? get audio;
  MediaStreamTrack? get video;

  /// Draws the camera for the person holding the device.
  RTCVideoRenderer? get renderer;
  Future<void> start();
  Future<void> startCamera();
  Future<void> stopCamera();
  Future<void> switchCamera();
  void setMuted(bool muted);
  Future<void> stop();
}

typedef LinkFactory =
    Future<MediaLink> Function({
      required String device,
      required Object iceServers,
      MediaStreamTrack? audio,
      MediaStreamTrack? video,
    });

class WebRtcLink implements MediaLink {
  final String device;
  final RTCPeerConnection _pc;
  final RTCVideoRenderer _renderer;
  final MediaStream _remote;
  WebRtcLink._(this.device, this._pc, this._renderer, this._remote);

  static Future<MediaLink> create({
    required String device,
    required Object iceServers,
    MediaStreamTrack? audio,
    MediaStreamTrack? video,
  }) async {
    final pc = await createPeerConnection({'iceServers': iceServers});
    RTCVideoRenderer? renderer;
    MediaStream? remote;
    try {
      renderer = RTCVideoRenderer();
      await renderer.initialize();
      remote = await createLocalMediaStream('remote-${randomId()}');
      final link = WebRtcLink._(device, pc, renderer, remote);
      await link._start(audio, video);
      return link;
    } catch (_) {
      await remote?.dispose();
      await renderer?.dispose();
      await pc.close();
      await pc.dispose();
      rethrow;
    }
  }

  RTCRtpTransceiver? _audioTx, _videoTx;
  MediaStreamTrack? _audio, _video;
  final List<RTCIceCandidate> _pending = [];
  final List<Json> _found = [];
  Timer? _flush;
  Future<void> _tracksReady = Future.value();
  final Set<String> _remoteTracks = {};
  bool _remoteSet = false, _closed = false, _bound = false;
  LinkState _state = LinkState.connecting;
  double _level = 0;
  int? _rtt;
  double _loss = 0;
  num _lastLost = 0, _lastReceived = 0;

  @override
  void Function()? onChange;
  @override
  void Function(List<Json> candidates)? onCandidates;

  @override
  LinkState get state => _state;
  @override
  RTCVideoRenderer? get renderer => _renderer;
  @override
  double get level => _level;
  @override
  int? get rttMs => _rtt;
  @override
  double get loss => _loss;

  Future<void> _start(MediaStreamTrack? audio, MediaStreamTrack? video) async {
    _audio = audio;
    _video = video;
    _pc.onIceCandidate = (candidate) {
      if (_closed || candidate.candidate == null) return;
      _found.add(candidate.toMap());
      // A gathering burst goes out as one request.
      _flush ??= Timer(const Duration(milliseconds: 60), () {
        _flush = null;
        final batch = _found.toList();
        _found.clear();
        if (!_closed && batch.isNotEmpty) onCandidates?.call(batch);
      });
    };
    if (androidRemoteStreams) {
      // The other side labels what it sends with a stream ([_transceivers],
      // [_bind]), which WebRTC announces without a track lookup.
      _pc.onAddStream = (stream) {
        if (_closed) return;
        _renderer.srcObject = stream;
        onChange?.call();
      };
    } else {
      _pc.onTrack = (event) {
        if (_closed) return;
        // Registered in a native stream of our own: on desktop the stream that
        // arrives with the track is not always one the renderer can find.
        if (_remoteTracks.length >= 2 || !_remoteTracks.add(event.track.id!)) {
          return;
        }
        _tracksReady = _tracksReady
            .then((_) async {
              if (_closed) return;
              await _remote.addTrack(event.track);
              if (_closed) return;
              _renderer.srcObject = _remote;
              onChange?.call();
            })
            .catchError((Object _) {});
      };
    }
    _pc.onConnectionState = (state) {
      if (_closed) return;
      final next = switch (state) {
        RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
          LinkState.connected,
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
          _state == LinkState.connecting
              ? LinkState.connecting
              : LinkState.reconnecting,
        RTCPeerConnectionState.RTCPeerConnectionStateFailed => LinkState.failed,
        RTCPeerConnectionState.RTCPeerConnectionStateClosed => LinkState.closed,
        _ => _state,
      };
      if (next != _state) {
        _state = next;
        onChange?.call();
      }
    };
  }

  /// Makes the two transceivers the offer is built from. The side that
  /// answers takes the ones its peer's offer made instead ([_bind]). What
  /// either side sends is labelled with a stream, so the other side can show
  /// it from `onAddStream` (see [androidRemoteStreams]); the label is
  /// [_remote]'s id, a stream that is only drawn from on desktop.
  Future<void> _transceivers() async {
    _audioTx = await _pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(
        direction: TransceiverDirection.SendRecv,
        streams: [_remote],
      ),
    );
    _videoTx = await _pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(
        direction: TransceiverDirection.SendRecv,
        streams: [_remote],
      ),
    );
    _bound = true;
    await _attach();
  }

  Future<void> _bind() async {
    if (_bound) return;
    for (final tx in await _pc.getTransceivers()) {
      final kind = tx.receiver.track?.kind;
      if (kind == 'audio') _audioTx ??= tx;
      if (kind == 'video') _videoTx ??= tx;
    }
    _bound = true;
    for (final tx in [_audioTx, _videoTx].whereType<RTCRtpTransceiver>()) {
      await tx.setDirection(TransceiverDirection.SendRecv);
      await tx.sender.setStreams([_remote]);
    }
    await _attach();
  }

  Future<void> _attach() async {
    await _audioTx?.sender.replaceTrack(_audio);
    await _videoTx?.sender.replaceTrack(_video);
  }

  @override
  Future<String> createOffer({bool restart = false}) async {
    if (!_bound) await _transceivers();
    final offer = await _pc.createOffer(restart ? {'iceRestart': true} : {});
    await _pc.setLocalDescription(offer);
    return offer.sdp!;
  }

  @override
  Future<String> accept(String offer) async {
    await _pc.setRemoteDescription(RTCSessionDescription(offer, 'offer'));
    await _bind();
    await _drain();
    final answer = await _pc.createAnswer();
    await _pc.setLocalDescription(answer);
    return answer.sdp!;
  }

  @override
  Future<void> acceptAnswer(String answer) async {
    await _pc.setRemoteDescription(RTCSessionDescription(answer, 'answer'));
    await _drain();
  }

  Future<void> _drain() async {
    _remoteSet = true;
    final pending = _pending.toList();
    _pending.clear();
    for (final candidate in pending) {
      if (_closed) return;
      await _pc.addCandidate(candidate);
    }
  }

  @override
  Future<void> addCandidates(List<Json> candidates) async {
    for (final j in candidates.take(64)) {
      if (j['candidate'] is! String) continue;
      final candidate = RTCIceCandidate(
        j['candidate'],
        j['sdpMid'] as String?,
        j['sdpMLineIndex'] as int?,
      );
      if (_remoteSet && !_closed) {
        await _pc.addCandidate(candidate);
      } else if (_pending.length < 128) {
        _pending.add(candidate);
      }
    }
  }

  @override
  Future<void> setTracks({
    MediaStreamTrack? audio,
    MediaStreamTrack? video,
  }) async {
    _audio = audio;
    _video = video;
    if (_bound && !_closed) await _attach();
  }

  @override
  Future<void> limitVideo({
    required int maxBitrate,
    required double scale,
  }) async {
    final sender = _videoTx?.sender;
    if (sender == null || _closed || _video == null) return;
    final parameters = sender.parameters;
    final encodings = parameters.encodings;
    if (encodings == null || encodings.isEmpty) return;
    encodings.first
      ..maxBitrate = maxBitrate
      ..scaleResolutionDownBy = scale;
    await sender.setParameters(parameters);
  }

  @override
  Future<void> poll() async {
    if (_closed || _state != LinkState.connected) return;
    final stats = await _pc.getStats();
    var level = 0.0;
    int? rtt;
    num lost = 0, received = 0;
    for (final s in stats) {
      final v = s.values;
      final kind = v['kind'] ?? v['mediaType'];
      if (s.type == 'inbound-rtp' && kind == 'audio') {
        level = (num.tryParse('${v['audioLevel']}') ?? 0).toDouble();
        lost += num.tryParse('${v['packetsLost']}') ?? 0;
        received += num.tryParse('${v['packetsReceived']}') ?? 0;
      } else if (s.type == 'candidate-pair' &&
          (v['nominated'] == true || v['state'] == 'succeeded')) {
        final seconds = num.tryParse('${v['currentRoundTripTime']}');
        if (seconds != null) rtt = (seconds * 1000).round();
      }
    }
    final lostNow = lost - _lastLost, receivedNow = received - _lastReceived;
    _lastLost = lost;
    _lastReceived = received;
    final total = lostNow + receivedNow;
    final loss = total > 0 && lostNow > 0 ? (lostNow / total).toDouble() : 0.0;
    final changed =
        (level - _level).abs() > .01 ||
        rtt != _rtt ||
        (loss - _loss).abs() > .02;
    _level = level.clamp(0, 1).toDouble();
    _rtt = rtt;
    _loss = loss;
    if (changed && !_closed) onChange?.call();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _state = LinkState.closed;
    _flush?.cancel();
    _renderer.srcObject = null;
    await _tracksReady;
    await _renderer.dispose();
    await _remote.dispose();
    await _pc.close();
    await _pc.dispose();
  }
}

/// The real microphone and camera.
class DeviceMedia implements LocalMedia {
  /// The microphone to use, from the saved choice; null for the default.
  final String? audioInput;
  DeviceMedia({this.audioInput});

  MediaStream? _mic, _cam;
  RTCVideoRenderer? _renderer;
  @override
  MediaStreamTrack? audio, video;

  @override
  RTCVideoRenderer? get renderer => _renderer;

  static bool get mobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Future<void> start() async {
    final media = await navigator.mediaDevices.getUserMedia({
      'audio': audioInput == null
          ? true
          : {
              // Desktop capture takes sourceId; deviceId routes playback.
              'optional': [
                {'sourceId': audioInput},
              ],
            },
      'video': false,
    });
    _mic = media;
    audio = media.getAudioTracks().firstOrNull;
    if (audio == null) throw StateError('No microphone found');
    _renderer = RTCVideoRenderer();
    await _renderer!.initialize();
  }

  @override
  Future<void> startCamera() async {
    if (_cam != null) return;
    final media = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': mobile ? {'facingMode': 'user'} : true,
    });
    final track = media.getVideoTracks().firstOrNull;
    if (track == null) {
      await media.dispose();
      throw StateError('No camera found');
    }
    _cam = media;
    video = track;
    _renderer?.srcObject = media;
  }

  @override
  Future<void> stopCamera() async {
    final cam = _cam;
    _cam = null;
    video = null;
    _renderer?.srcObject = null;
    if (cam == null) return;
    for (final track in cam.getTracks()) {
      await track.stop();
    }
    await cam.dispose();
  }

  @override
  Future<void> switchCamera() async {
    final track = video;
    if (track != null) await Helper.switchCamera(track);
  }

  @override
  void setMuted(bool muted) {
    audio?.enabled = !muted;
  }

  @override
  Future<void> stop() async {
    await stopCamera();
    final mic = _mic;
    _mic = null;
    audio = null;
    if (mic != null) {
      for (final track in mic.getTracks()) {
        await track.stop();
      }
      await mic.dispose();
    }
    await _renderer?.dispose();
    _renderer = null;
  }
}
