import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ournet_core/ournet_core.dart';
import 'call_link.dart';
import 'calls.dart' show iceServers;
import 'network.dart';

/// One device in a group call.
class CallMember {
  final String device;
  final String person;

  /// The order devices joined in, given by the host. The device that joined
  /// later makes the connection to the earlier one, so two devices never
  /// both offer; the lowest is the host.
  int seq;
  bool muted;
  bool video;
  DateTime seen;
  CallMember(
    this.device,
    this.person,
    this.seq,
    this.seen, {
    this.muted = false,
    this.video = false,
  });
}

/// What a device knows about a group's call: who is in it and who hosts it.
/// Kept in memory only, like a position: nothing about a call is stored.
class CallInfo {
  final String call;
  String host;
  int rev;

  /// When the host last said so; a call nobody has mentioned for
  /// [GroupCalls.ttl] is over.
  DateTime heard;
  final Map<String, CallMember> members;
  CallInfo(this.call, this.host, this.rev, this.heard, this.members);

  int get count => members.length;

  /// People, not devices: someone in the call on two devices counts once.
  Set<String> get people => {for (final m in members.values) m.person};
  List<CallMember> get ordered =>
      members.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));
}

/// How a participant appears on the call screen.
class CallParticipant {
  final String device, person;
  final bool self, muted, video, speaking;
  final LinkState? link;
  final RTCVideoRenderer? renderer;
  const CallParticipant({
    required this.device,
    required this.person,
    required this.self,
    required this.muted,
    required this.video,
    required this.speaking,
    required this.link,
    required this.renderer,
  });
}

enum CallQuality { good, fair, poor }

class _Peer {
  final String device;
  final bool initiator;
  MediaLink? link;
  int attempts = 0;
  DateTime started;
  DateTime? lastAttempt;
  DateTime? spoke;
  bool dialling = false;

  /// The other side accepted our offer (the answer came back).
  bool answered = false;
  _Peer(this.device, this.initiator, this.started);
}

/// Voice and video calls for a private group, in the manner of a voice channel:
/// nobody is rung. A call is simply there while anyone is in it; the group sees
/// how many are in and joins when they like.
///
/// There is no server, so there is nobody to ask who is in a call. The first
/// device to join becomes its host. The host numbers devices as they join,
/// keeps the roster, and tells every other device of the group (so the group
/// list and the conversation can show "3 in call" and a Join button). It is
/// also the one place a joiner asks. The host is a coordinator, not a relay:
/// media goes directly between every pair of devices (a mesh), which is the
/// cheapest thing for the voices of a handful of friends (a voice stream is
/// about 30 kbit/s) and means no one's home connection carries everybody
/// else's call. When the host leaves, the device with the next lowest number
/// takes over, which every device works out for itself.
///
/// Pairs connect with ordinary WebRTC. A device that joins offers to each
/// device that was already in; the answer comes back in the reply, so
/// signalling is one request per pair, plus candidates sent in bursts.
class GroupCalls extends ChangeNotifier {
  /// The most devices in one call. Every device sends its camera to each of
  /// the others, so more would not work for video and gains little for voice.
  static const maxDevices = 8;

  /// A call nobody has said anything about for this long has ended.
  static const ttl = Duration(seconds: 80);

  /// How often the host repeats the roster, and a member says it is there.
  static const announceEvery = Duration(seconds: 30);
  static const beatEvery = Duration(seconds: 20);

  /// Devices are told about a call only if heard from within this long.
  static const recent = Duration(minutes: 10);

  final Network network;

  /// The people in a group (null when this device is not in it).
  final Future<Set<String>?> Function(String space) members;
  final LinkFactory _links;
  final LocalMedia Function() _newMedia;
  final DateTime Function() _now;

  /// True while a call that is not a group call is using the microphone.
  final bool Function()? otherCallActive;

  /// Whether to pick audio devices and speaker routing; off in tests, which
  /// have no audio hardware.
  final bool routing;

  GroupCalls(
    this.network, {
    required this.members,
    LinkFactory? links,
    LocalMedia Function()? media,
    DateTime Function()? now,
    this.otherCallActive,
    this.routing = true,
  }) : _links = links ?? WebRtcLink.create,
       _newMedia =
           media ??
           (() => DeviceMedia(
             audioInput:
                 network.node.store.setting('callAudioInput') as String?,
           )),
       _now = now ?? DateTime.now {
    network.groupCall = _handle;
    network.peerSeenListeners.add(_seen);
  }

  Node get node => network.node;
  String get _me => node.identity.device;

  final Map<String, CallInfo> _info = {};
  final Map<String, _Peer> _peers = {};
  final Set<String> _unsupported = {};
  final Map<String, ({Set<String>? people, DateTime at})> _people = {};

  /// The group in the call this device is in or joining, if any.
  String? space;
  String? _call;
  String phase = 'idle';
  String? error;
  bool muted = false;
  bool camera = false;
  bool speaker = false;
  DateTime? joinedAt;
  LocalMedia? _media;
  int _generation = 0;
  Timer? _timer, _stats, _soon;
  DateTime _lastBeat = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastAnnounce = DateTime.fromMillisecondsSinceEpoch(0);
  bool _polling = false, _closed = false;

  List<MediaDeviceInfo> audioInputs = [];
  List<MediaDeviceInfo> audioOutputs = [];
  String? audioInput;
  String? audioOutput;

  bool get active => phase != 'idle';
  CallInfo? get _mine => space == null ? null : _info[space];
  bool get isHost => _mine?.host == _me;
  RTCVideoRenderer? get localRenderer => _media?.renderer;

  /// The call in [space], if one is going: this device's own, or one it has
  /// been told about recently.
  CallInfo? infoFor(String space) {
    final info = _info[space];
    if (info == null) return null;
    if (space == this.space && active) return info;
    return _now().difference(info.heard) > ttl ? null : info;
  }

  /// Whether this device is in the call of [space].
  bool inCall(String space) => this.space == space && active;

  /// Groups with a call going.
  List<String> get live => [
    for (final space in _info.keys)
      if (infoFor(space) != null) space,
  ];

  /// Everyone on the call screen, this device first.
  List<CallParticipant> get participants {
    final info = _mine;
    if (info == null) return const [];
    final now = _now();
    return [
      for (final m in info.ordered)
        if (m.device == _me)
          CallParticipant(
            device: m.device,
            person: m.person,
            self: true,
            muted: muted,
            video: camera,
            speaking: false,
            link: null,
            renderer: _media?.renderer,
          )
        else
          CallParticipant(
            device: m.device,
            person: m.person,
            self: false,
            muted: m.muted,
            video: m.video,
            speaking:
                _peers[m.device]?.spoke != null &&
                now.difference(_peers[m.device]!.spoke!) <
                    const Duration(milliseconds: 600),
            link: _peers[m.device]?.link?.state ?? LinkState.connecting,
            renderer: _peers[m.device]?.link?.renderer,
          ),
    ]..sort((a, b) => a.self == b.self ? 0 : (a.self ? -1 : 1));
  }

  /// The worst connection to anyone in the call.
  CallQuality get quality {
    var worst = CallQuality.good;
    for (final peer in _peers.values) {
      final link = peer.link;
      if (link == null || link.state != LinkState.connected) continue;
      final rtt = link.rttMs ?? 0;
      if (rtt > 400 || link.loss > .1) return CallQuality.poor;
      if (rtt > 200 || link.loss > .04) worst = CallQuality.fair;
    }
    return worst;
  }

  /// How many other devices are connected to this one.
  int get connected =>
      _peers.values.where((p) => p.link?.state == LinkState.connected).length;

  // ---------------------------------------------------------------- joining

  /// Joins the call in [space], or starts one if none is going.
  Future<void> join(String space, {bool video = false}) async {
    if (phase != 'idle') throw StateError('Already in a call');
    if (otherCallActive?.call() == true) {
      throw StateError('Finish the current call first');
    }
    final people = await members(space);
    if (people == null || !people.contains(node.person)) {
      throw StateError('Not a member of this group');
    }
    final generation = ++_generation;
    this.space = space;
    phase = 'joining';
    error = null;
    muted = false;
    camera = false;
    notifyListeners();
    try {
      final media = _newMedia();
      _media = media;
      await media.start();
      _check(generation);
      if (routing) await _prepareAudio(generation);
      var target = infoFor(space) ?? await _ask(space);
      _check(generation);
      var joined = false;
      if (target != null) joined = await _requestJoin(space, target);
      _check(generation);
      if (!joined) _begin(space);
      phase = 'active';
      joinedAt = _now();
      _lastBeat = _now();
      _timer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(tick()),
      );
      _stats = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => unawaited(_poll()),
      );
      notifyListeners();
      _dialLower();
      unawaited(_announce());
      if (video) {
        try {
          await toggleCamera(on: true);
        } catch (e) {
          error = 'Camera: $e';
        }
      }
    } catch (e) {
      // Leaving while still joining cancels it without a complaint.
      if (generation != _generation) return;
      await _teardown(announce: false);
      error = '$e'.replaceFirst('Bad state: ', '');
      rethrow;
    }
  }

  void _check(int generation) {
    if (generation != _generation) throw StateError('Call cancelled');
  }

  Future<void> _prepareAudio(int generation) async {
    final mobile = DeviceMedia.mobile;
    try {
      if (mobile) {
        speaker = true;
        await Helper.setSpeakerphoneOnButPreferBluetooth();
      } else {
        final devices = await navigator.mediaDevices.enumerateDevices();
        _check(generation);
        audioInputs = devices.where((d) => d.kind == 'audioinput').toList();
        audioOutputs = devices.where((d) => d.kind == 'audiooutput').toList();
        final savedInput = node.store.setting('callAudioInput');
        final savedOutput = node.store.setting('callAudioOutput');
        audioInput = audioInputs.any((d) => d.deviceId == savedInput)
            ? savedInput as String
            : null;
        audioOutput = audioOutputs.any((d) => d.deviceId == savedOutput)
            ? savedOutput as String
            : null;
        if (audioOutput != null) await Helper.selectAudioOutput(audioOutput!);
      }
    } catch (e) {
      if (generation == _generation && e is! StateError) {
        error = 'Audio devices: $e';
      }
    }
  }

  /// Starts a call of this device's own: it is the host, number 0.
  void _begin(String space) {
    final info = CallInfo(randomId(), _me, 1, _now(), {
      _me: CallMember(_me, node.person, 0, _now()),
    });
    _info[space] = info;
    _call = info.call;
  }

  /// Asks the call's host (then the others in it) to let this device in.
  /// False when no one in the call answers, so the information was stale.
  Future<bool> _requestJoin(String space, CallInfo info) async {
    final order = <String>[
      info.host,
      for (final m in info.ordered)
        if (m.device != info.host) m.device,
    ];
    final tried = <String>{};
    while (order.isNotEmpty) {
      final device = order.removeAt(0);
      if (device == _me || !tried.add(device)) continue;
      try {
        final reply = await _send(device, {
          'op': 'join',
          'space': space,
          'call': info.call,
          'muted': muted,
        });
        if (reply['full'] == true) throw StateError('This call is full');
        if (reply['ok'] == true) {
          final people = await members(space);
          final adopted = _parse(space, reply, people ?? const {});
          if (adopted == null) continue;
          final seq = reply['seq'];
          if (seq is! int) continue;
          adopted.members[_me] = CallMember(_me, node.person, seq, _now());
          _info[space] = adopted;
          _call = adopted.call;
          return true;
        }
        // Not the host any more: try who it says is.
        if (reply['host'] case final String host when !tried.contains(host)) {
          order.insert(0, host);
        }
      } on StateError catch (e) {
        if (e.message == 'This call is full') rethrow;
      } catch (_) {}
    }
    _info.remove(space);
    return false;
  }

  /// Asks the group's devices whether a call is going, for a device that has
  /// not been told. Resolves on the first answer, or when everyone has had
  /// their say.
  Future<CallInfo?> _ask(String space) async {
    final devices = await _audience(space);
    if (devices.isEmpty) return null;
    final people = await members(space) ?? const {};
    CallInfo? found;
    final done = Completer<void>();
    unawaited(
      _fan(devices, (device) async {
        final reply = await _send(device, {'op': 'ask', 'space': space});
        if (found == null && reply['info'] is Map) {
          found = _parse(space, (reply['info'] as Map).cast(), people);
          if (found != null && !done.isCompleted) done.complete();
        }
      }).whenComplete(() {
        if (!done.isCompleted) done.complete();
      }),
    );
    await done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    if (found != null) _info[space] = found!;
    return found;
  }

  /// Connects to every device that joined before this one.
  void _dialLower() {
    final info = _mine;
    final mine = info?.members[_me]?.seq;
    if (info == null || mine == null) return;
    for (final m in info.ordered) {
      if (m.device != _me && m.seq < mine && !_peers.containsKey(m.device)) {
        unawaited(_dial(m.device).catchError((Object _) {}));
      }
    }
  }

  // ------------------------------------------------------------ connections

  Future<MediaLink> _makeLink(String device) => _links(
    device: device,
    iceServers: iceServers(
      node.store.setting('iceServers'),
      local: network.local,
    ),
    audio: _media?.audio,
    video: _media?.video,
  );

  void _wire(_Peer peer, MediaLink link) {
    final generation = _generation;
    final session = _call;
    peer.link = link;
    link.onChange = () {
      if (generation != _generation) return;
      final level = link.level;
      if (level > .03) peer.spoke = _now();
      _notifySoon();
    };
    link.onCandidates = (candidates) {
      if (generation != _generation || session != _call || space == null) {
        return;
      }
      unawaited(
        _send(peer.device, {
          'op': 'ice',
          'space': space,
          'call': session,
          'candidates': candidates,
        }).catchError((Object _) => <String, dynamic>{}),
      );
    };
  }

  /// Offers a media link to [device]. The answer is the reply.
  Future<void> _dial(String device, {bool restart = false}) async {
    final generation = _generation;
    final info = _mine;
    if (info == null || space == null) return;
    var peer = _peers[device];
    if (peer != null && peer.dialling) return;
    final session = _call;
    final fresh = !restart || peer?.link == null;
    final attempts = peer?.attempts ?? 0;
    if (fresh) {
      await peer?.link?.close();
      peer = _peers[device] = _Peer(device, true, _now());
    }
    final p = peer!;
    p.attempts = attempts + 1;
    p.dialling = true;
    p.lastAttempt = _now();
    try {
      final link = fresh ? await _makeLink(device) : p.link!;
      if (generation != _generation) {
        if (fresh) await link.close();
        return;
      }
      if (fresh) _wire(p, link);
      final sdp = await link.createOffer(restart: !fresh);
      final reply = await _send(device, {
        'op': fresh ? 'offer' : 'restart',
        'space': space,
        'call': session,
        'sdp': sdp,
        'seq': info.members[_me]?.seq,
        'muted': muted,
        'video': camera,
      });
      if (generation != _generation) return;
      if (reply['sdp'] is! String) {
        throw StateError('${reply['error'] ?? 'Refused'}');
      }
      await link.acceptAnswer(reply['sdp']);
      p.answered = true;
      _applyLimits();
    } catch (_) {
      // Retried from [tick] while the device is still in the call.
    } finally {
      p.dialling = false;
      _notifySoon();
    }
  }

  Future<Json> _answer(
    String device,
    String space,
    Map<dynamic, dynamic> m, {
    required bool restart,
  }) async {
    final generation = _generation;
    final sdp = m['sdp'];
    if (sdp is! String || sdp.length > 200000) throw StateError('Bad offer');
    var peer = _peers[device];
    if (restart) {
      if (peer?.link == null) throw StateError('No such link');
      final answer = await peer!.link!.accept(sdp);
      return {'ok': true, 'sdp': answer};
    }
    if (peer == null && _peers.length >= maxDevices - 1) {
      throw StateError('This call is full');
    }
    await peer?.link?.close();
    peer = _peers[device] = _Peer(device, false, _now());
    final link = await _makeLink(device);
    if (generation != _generation) {
      await link.close();
      throw StateError('Call ended');
    }
    _wire(peer, link);
    final answer = await link.accept(sdp);
    final info = _mine;
    final person = node.contacts[device]?.person;
    if (info != null && person != null) {
      final member = info.members.putIfAbsent(
        device,
        () => CallMember(
          device,
          person,
          m['seq'] is int ? m['seq'] as int : 1 << 20,
          _now(),
        ),
      );
      member
        ..muted = m['muted'] == true
        ..video = m['video'] == true
        ..seen = _now();
    }
    _applyLimits();
    notifyListeners();
    return {'ok': true, 'sdp': answer};
  }

  /// Limits what the camera sends to each device so that the total stays
  /// within what a home connection can upload however many are in the call.
  void _applyLimits() {
    if (!camera) return;
    final others = max(1, _peers.length);
    final bitrate = (1200000 / others).clamp(120000, 1200000).round();
    final scale = others <= 1
        ? 1.0
        : others <= 3
        ? 1.5
        : others <= 5
        ? 2.0
        : 3.0;
    for (final peer in _peers.values) {
      unawaited(
        (peer.link?.limitVideo(maxBitrate: bitrate, scale: scale) ??
                Future<void>.value())
            .catchError((Object _) {}),
      );
    }
  }

  // --------------------------------------------------------------- controls

  void toggleMute() {
    muted = !muted;
    _media?.setMuted(muted);
    notifyListeners();
    _tellState();
  }

  Future<void> toggleCamera({bool? on}) async {
    final media = _media;
    if (media == null || !active) return;
    final want = on ?? !camera;
    if (want == camera) return;
    if (want) {
      await media.startCamera();
      camera = true;
    } else {
      camera = false;
      await media.stopCamera();
    }
    for (final peer in _peers.values) {
      unawaited(
        (peer.link?.setTracks(audio: media.audio, video: media.video) ??
                Future<void>.value())
            .catchError((Object _) {}),
      );
    }
    _applyLimits();
    notifyListeners();
    _tellState();
  }

  Future<void> switchCamera() async {
    await _media?.switchCamera();
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    await Helper.setSpeakerphoneOn(!speaker);
    speaker = !speaker;
    notifyListeners();
  }

  Future<void> selectAudioOutput(String device) async {
    await Helper.selectAudioOutput(device);
    audioOutput = device;
    node.store.set('callAudioOutput', device);
    notifyListeners();
  }

  Future<void> selectAudioInput(String device) async {
    await Helper.selectAudioInput(device);
    audioInput = device;
    node.store.set('callAudioInput', device);
    notifyListeners();
  }

  void _tellState() {
    final info = _mine;
    info?.members[_me]
      ?..muted = muted
      ..video = camera;
    for (final device in {..._peers.keys, ?info?.host}) {
      if (device == _me) continue;
      unawaited(
        _send(device, {
          'op': 'state',
          'space': space,
          'call': _call,
          'muted': muted,
          'video': camera,
        }).catchError((Object _) => <String, dynamic>{}),
      );
    }
  }

  /// Leaves the call. The others are told, and the next in line hosts.
  Future<void> leave() => _teardown(announce: true);

  Future<void> _teardown({required bool announce}) async {
    if (phase == 'idle' && this.space == null) return;
    final info = _mine;
    final space = this.space;
    final call = _call;
    _generation++;
    _timer?.cancel();
    _stats?.cancel();
    _soon?.cancel();
    _soon = null;
    final others = [
      for (final m in info?.members.values ?? const <CallMember>[])
        if (m.device != _me) m.device,
    ];
    final links = [for (final p in _peers.values) p.link];
    _peers.clear();
    phase = 'ending';
    this.space = null;
    _call = null;
    muted = false;
    camera = false;
    speaker = false;
    joinedAt = null;
    notifyListeners();
    if (announce && space != null && info != null) {
      for (final device in others) {
        unawaited(
          _send(device, {
            'op': 'leave',
            'space': space,
            'call': call,
          }).catchError((Object _) => <String, dynamic>{}),
        );
      }
      if (others.isEmpty) {
        // The last one out: tell the group at once rather than leaving them
        // to wait for the call to time out.
        _info.remove(space);
        final audience = await _audience(space);
        unawaited(
          _fan(
            audience,
            (device) => _send(device, {
              'op': 'presence',
              'space': space,
              'call': call,
              'host': _me,
              'rev': info.rev + 1,
              'members': const [],
            }),
          ),
        );
      } else {
        info.members.remove(_me);
        _info[space] = info;
      }
    } else if (space != null) {
      _info.remove(space);
    }
    for (final link in links) {
      await link?.close();
    }
    await _media?.stop();
    _media = null;
    audioInputs = [];
    audioOutputs = [];
    audioInput = null;
    audioOutput = null;
    phase = 'idle';
    notifyListeners();
  }

  // ------------------------------------------------------------- presence

  /// The group's devices that can be told about a call: admitted, supporting
  /// group calls, and heard from lately (or already connected).
  Future<List<String>> _audience(String space) async {
    final people = await members(space);
    if (people == null) return const [];
    final now = _now();
    return [
      for (final c in node.contacts.values)
        if (people.contains(c.person) &&
            c.device != _me &&
            node.allowedPeer(c.device) &&
            !_unsupported.contains(c.device) &&
            (_peers[c.device]?.link?.state == LinkState.connected ||
                _heard(c.device, now)))
          c.device,
    ];
  }

  bool _heard(String device, DateTime now) {
    for (final at in [network.lastInbound[device], network.lastSync[device]]) {
      if (at != null && now.difference(at) <= recent) return true;
    }
    return false;
  }

  Json _snapshot(CallInfo info) => {
    'call': info.call,
    'host': info.host,
    'rev': info.rev,
    'members': [
      for (final m in info.ordered)
        {'d': m.device, 's': m.seq, 'm': m.muted, 'v': m.video},
    ],
  };

  /// Reads a roster from the wire, keeping only devices of the group's people
  /// that this device knows.
  CallInfo? _parse(String space, Map<dynamic, dynamic> j, Set<String> people) {
    final call = j['call'],
        host = j['host'],
        rev = j['rev'],
        list = j['members'];
    if (call is! String ||
        call.length > 64 ||
        host is! String ||
        rev is! int ||
        list is! List ||
        list.length > 16) {
      return null;
    }
    final now = _now();
    final members = <String, CallMember>{};
    for (final e in list) {
      if (e is! Map || e['d'] is! String || e['s'] is! int) continue;
      final device = e['d'] as String;
      final person = device == _me
          ? node.person
          : node.contacts[device]?.person;
      if (person == null || !people.contains(person)) continue;
      members[device] = CallMember(
        device,
        person,
        e['s'] as int,
        now,
        muted: e['m'] == true,
        video: e['v'] == true,
      );
    }
    if (members.isEmpty) return null;
    return CallInfo(call, host, rev, now, members);
  }

  /// Tells the group's devices who is in the call. Only the host does.
  Future<void> _announce({String? to}) async {
    final space = this.space, info = _mine;
    if (space == null || info == null || info.host != _me) return;
    _lastAnnounce = _now();
    final payload = {'op': 'presence', 'space': space, ..._snapshot(info)};
    if (to != null) {
      await _send(to, payload).then<void>((_) {}, onError: (Object _) {});
      return;
    }
    final audience = await _audience(space);
    await _fan(audience, (device) => _send(device, payload));
  }

  /// A device that has just synced with this one hears about the call.
  void _seen(String device) {
    final space = this.space, info = _mine;
    if (space == null || info == null || info.host != _me || !active) return;
    final person = node.contacts[device]?.person;
    if (person == null || _unsupported.contains(device)) return;
    unawaited(
      members(space)
          .then((people) {
            if (people != null && people.contains(person)) {
              return _announce(to: device);
            }
          })
          .catchError((Object _) {}),
    );
  }

  // ------------------------------------------------------------ signalling

  Future<Json> _send(String device, Json payload) async {
    if (_unsupported.contains(device)) throw StateError('Unsupported');
    try {
      return await network
          .request(device, {'type': 'groupcall', 'payload': payload})
          .timeout(const Duration(seconds: 12));
    } on StateError catch (e) {
      // An older build refuses the request; do not keep asking it.
      if (e.message == 'Unknown request') _unsupported.add(device);
      rethrow;
    }
  }

  Future<void> _fan(
    Iterable<String> devices,
    Future<void> Function(String) action, {
    int width = 6,
  }) async {
    final queue = devices.toList();
    final workers = min(width, queue.length);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        try {
          await action(queue.removeLast());
        } catch (_) {}
      }
    }

    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  }

  Future<Set<String>?> _peopleOf(String space) async {
    final cached = _people[space];
    if (cached != null &&
        _now().difference(cached.at) < const Duration(seconds: 30)) {
      return cached.people;
    }
    final people = await members(space);
    _people[space] = (people: people, at: _now());
    return people;
  }

  bool _inCall(String space, Object? call) =>
      this.space == space && _call == call && call != null && active;

  Future<Json> _handle(String device, Json m) async {
    final contact = node.contacts[device];
    if (contact == null || !node.allowedPeer(device)) {
      throw StateError('Device not admitted');
    }
    final op = m['op'], space = m['space'];
    if (op is! String || space is! String || space.length > 128) {
      throw StateError('Bad call message');
    }
    final people = await _peopleOf(space);
    if (people == null ||
        !people.contains(contact.person) ||
        !people.contains(node.person)) {
      throw StateError('Not in this group');
    }
    final info = _info[space];
    switch (op) {
      case 'ask':
        return {
          'info': info != null && infoFor(space) != null
              ? _snapshot(info)
              : null,
        };
      case 'presence':
        _onPresence(device, space, m, people);
        return {};
      case 'join':
        return _admit(device, space, m, contact.person);
      case 'offer':
        if (!_inCall(space, m['call'])) throw StateError('Not in this call');
        return _answer(device, space, m, restart: false);
      case 'restart':
        if (!_inCall(space, m['call'])) throw StateError('Not in this call');
        return _answer(device, space, m, restart: true);
      case 'ice':
        if (!_inCall(space, m['call'])) return {'ignored': true};
        final candidates = m['candidates'];
        final link = _peers[device]?.link;
        if (link != null && candidates is List) {
          await link.addCandidates(
            candidates
                .whereType<Map>()
                .map((c) => c.cast<String, dynamic>())
                .toList(),
          );
        }
        return {};
      case 'state':
        if (!_inCall(space, m['call'])) return {};
        final member = info?.members[device];
        if (member != null) {
          member
            ..muted = m['muted'] == true
            ..video = m['video'] == true
            ..seen = _now();
          _notifySoon();
        }
        return {};
      case 'beat':
        if (!_inCall(space, m['call'])) return {};
        info?.members[device]?.seen = _now();
        return {};
      case 'leave':
        if (_inCall(space, m['call'])) await _removed(device);
        return {};
      default:
        throw StateError('Unknown call message');
    }
  }

  /// The host admits a device to the call it hosts.
  Future<Json> _admit(
    String device,
    String space,
    Json m,
    String person,
  ) async {
    final info = _mine;
    if (info == null || this.space != space || !active || _call != m['call']) {
      return {'ok': false, 'host': infoFor(space)?.host};
    }
    if (info.host != _me) return {'ok': false, 'host': info.host};
    final existing = info.members[device];
    if (existing == null && info.count >= maxDevices) return {'full': true};
    final member =
        existing ??
        CallMember(
          device,
          person,
          info.members.values.fold<int>(-1, (a, b) => max(a, b.seq)) + 1,
          _now(),
        );
    member
      ..muted = m['muted'] == true
      ..seen = _now();
    info.members[device] = member;
    if (existing == null) info.rev++;
    notifyListeners();
    unawaited(_announce());
    final reply = <String, dynamic>{
      'ok': true,
      ..._snapshot(info),
      'seq': member.seq,
    };
    return reply;
  }

  void _onPresence(String device, String space, Json m, Set<String> people) {
    final call = m['call'];
    if (call is! String || m['host'] != device) return;
    final list = m['members'];
    final existing = _info[space];
    if (list is List && list.isEmpty) {
      if (existing?.call == call && !(this.space == space && active)) {
        _info.remove(space);
        notifyListeners();
      }
      return;
    }
    final incoming = _parse(space, m, people);
    if (incoming == null) return;
    final mineActive = this.space == space && active;
    if (existing != null && existing.call != call) {
      if (mineActive && existing.call == _call) {
        // Two calls started at once; the lower id wins, and the other side
        // joins it.
        if (call.compareTo(existing.call) < 0) {
          unawaited(_merge(space, incoming).catchError((Object _) {}));
        }
        return;
      }
    } else if (existing != null &&
        existing.host == device &&
        incoming.rev < existing.rev) {
      return;
    }
    if (existing != null && existing.call == call) {
      // Keep what this device already knows of each member's state, and itself.
      for (final e in incoming.members.entries) {
        final old = existing.members[e.key];
        if (old != null && e.key != device) {
          e.value
            ..muted = old.muted
            ..video = old.video;
        }
      }
      final me = existing.members[_me];
      if (mineActive && me != null) incoming.members[_me] = me;
    }
    _info[space] = incoming;
    if (mineActive && _call == call) {
      _dialLower();
      _applyLimits();
    }
    _notifySoon();
  }

  Future<void> _merge(String space, CallInfo winner) async {
    final video = camera;
    await _teardown(announce: false);
    _info[space] = winner;
    await join(space, video: video);
  }

  /// A device has left (or been dropped): close its link and pass on hosting.
  Future<void> _removed(String device) async {
    final info = _mine;
    final peer = _peers.remove(device);
    await peer?.link?.close();
    if (info == null) return;
    info.members.remove(device);
    _rehost(info);
    if (info.host == _me) info.rev++;
    notifyListeners();
  }

  /// Hosting goes to the lowest number still in the call; every device works
  /// this out the same way. The new host tells the group.
  void _rehost(CallInfo info) {
    if (info.members.isEmpty) return;
    final host = info.ordered.first.device;
    if (host == info.host) return;
    info.host = host;
    info.heard = _now();
    if (host == _me) {
      for (final m in info.members.values) {
        m.seen = _now();
      }
      info.rev++;
      unawaited(_announce());
    }
  }

  // ----------------------------------------------------------------- timers

  /// Housekeeping, every couple of seconds: the host drops members who have
  /// gone quiet and repeats the roster, members check in, links that did not
  /// connect are tried again, and calls nobody has mentioned lapse.
  @visibleForTesting
  Future<void> tick() async {
    if (_closed) return;
    final now = _now();
    var changed = false;
    for (final space in _info.keys.toList()) {
      if (space != this.space && infoFor(space) == null) {
        _info.remove(space);
        changed = true;
      }
    }
    final info = _mine;
    if (active && phase == 'active' && info != null) {
      if (info.host == _me) {
        for (final m in info.members.values.toList()) {
          if (m.device != _me && now.difference(m.seen) > ttl) {
            await _removed(m.device);
            unawaited(_announce());
            changed = true;
          }
        }
        if (now.difference(_lastAnnounce) >= announceEvery) {
          unawaited(_announce());
        }
      } else {
        if (now.difference(info.heard) > ttl) {
          // The host has gone without saying so.
          final host = info.host;
          info.members.remove(host);
          await _peers.remove(host)?.link?.close();
          _rehost(info);
          changed = true;
        } else if (now.difference(_lastBeat) >= beatEvery) {
          _lastBeat = now;
          unawaited(
            _send(info.host, {
              'op': 'beat',
              'space': space,
              'call': _call,
            }).catchError((Object _) => <String, dynamic>{}),
          );
        }
      }
      _redial(info, now);
    }
    if (changed) notifyListeners();
  }

  /// Offers again to a device that did not connect, or whose link was lost.
  void _redial(CallInfo info, DateTime now) {
    final mine = info.members[_me]?.seq;
    if (mine == null) return;
    for (final m in info.ordered) {
      if (m.device == _me || m.seq >= mine) continue;
      final peer = _peers[m.device];
      if (peer == null) {
        unawaited(_dial(m.device).catchError((Object _) {}));
        continue;
      }
      final last = peer.lastAttempt ?? peer.started;
      if (peer.dialling) continue;
      final since = now.difference(last);
      final state = peer.link?.state;
      if (!peer.answered) {
        // The offer did not get through (the other device may still be
        // joining): offer again, and keep trying for a while.
        if (since >= const Duration(seconds: 4) && peer.attempts < 10) {
          unawaited(_dial(m.device).catchError((Object _) {}));
        }
      } else if (state == LinkState.connecting) {
        if (since >= const Duration(seconds: 20) && peer.attempts < 6) {
          unawaited(_dial(m.device).catchError((Object _) {}));
        }
      } else if (state == LinkState.reconnecting || state == LinkState.failed) {
        if (since >= const Duration(seconds: 6)) {
          // New candidates on the same link; a new link if that has not helped.
          unawaited(
            _dial(
              m.device,
              restart: peer.attempts < 4,
            ).catchError((Object _) {}),
          );
        }
      }
    }
  }

  Future<void> _poll() async {
    if (_polling || !active) return;
    _polling = true;
    try {
      await Future.wait([
        for (final peer in _peers.values.toList())
          (peer.link?.poll() ?? Future<void>.value()).catchError((Object _) {}),
      ]);
    } finally {
      _polling = false;
    }
  }

  /// Several changes in a moment (levels from every link, a roster) become
  /// one rebuild.
  void _notifySoon() {
    if (_soon != null || _closed) return;
    _soon = Timer(const Duration(milliseconds: 200), () {
      _soon = null;
      if (!_closed) notifyListeners();
    });
  }

  Future<void> close() async {
    _closed = true;
    if (network.groupCall == _handle) network.groupCall = null;
    network.peerSeenListeners.remove(_seen);
    await _teardown(announce: true);
    dispose();
  }
}
