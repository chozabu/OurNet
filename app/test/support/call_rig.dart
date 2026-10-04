import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ournet/services/call_link.dart';
import 'package:ournet/services/group_calls.dart';
import 'package:ournet/services/network.dart';
import 'package:ournet_core/ournet_core.dart';

/// Devices joined by an in-memory wire: a request goes straight to the other
/// device's group-call handler, as the transport would deliver it.
class Wire {
  final devices = <String, Dev>{};
  final down = <String>{};
  final log = <String>[];
  DateTime clock = DateTime(2026, 10, 4, 12);
}

class Dev extends Network {
  final Wire wire;
  Dev(super.node, this.wire);
  late GroupCalls calls;
  late String name;

  @override
  Future<Json> request(String device, Json message) async {
    final target = wire.devices[device];
    if (target == null || wire.down.contains(device)) {
      throw StateError('unreachable');
    }
    final payload = message['payload'] as Json;
    wire.log.add('$name>${target.name} ${payload['op']}');
    final handler = target.groupCall;
    if (handler == null) throw StateError('Unknown request');
    return await handler(node.identity.device, payload);
  }
}

class FakeLink implements MediaLink {
  final String device;
  FakeLink(this.device);
  @override
  LinkState state = LinkState.connecting;
  @override
  RTCVideoRenderer? get renderer => null;
  @override
  double level = 0;
  @override
  int? rttMs;
  @override
  double loss = 0;
  @override
  void Function()? onChange;
  @override
  void Function(List<Json> candidates)? onCandidates;
  final offers = <bool>[];
  var limits = 0;
  MediaStreamTrack? video;
  @override
  Future<String> createOffer({bool restart = false}) async {
    offers.add(restart);
    return 'offer';
  }

  @override
  Future<String> accept(String offer) async {
    state = LinkState.connected;
    return 'answer';
  }

  @override
  Future<void> acceptAnswer(String answer) async {
    state = LinkState.connected;
    onChange?.call();
  }

  @override
  Future<void> addCandidates(List<Json> candidates) async {}
  @override
  Future<void> setTracks({
    MediaStreamTrack? audio,
    MediaStreamTrack? video,
  }) async {
    this.video = video;
  }

  @override
  Future<void> limitVideo({
    required int maxBitrate,
    required double scale,
  }) async {
    limits++;
  }

  @override
  Future<void> poll() async {}
  @override
  Future<void> close() async => state = LinkState.closed;
}

class FakeMedia implements LocalMedia {
  bool camera = false, muted = false, stopped = false;
  @override
  MediaStreamTrack? get audio => null;
  @override
  MediaStreamTrack? get video => null;
  @override
  RTCVideoRenderer? get renderer => null;
  @override
  Future<void> start() async {}
  @override
  Future<void> startCamera() async => camera = true;
  @override
  Future<void> stopCamera() async => camera = false;
  @override
  Future<void> switchCamera() async {}
  @override
  void setMuted(bool value) => muted = value;
  @override
  Future<void> stop() async => stopped = true;
}

/// A group of fake devices on one [Wire].
class Rig {
  static const space = 'group-space';
  Wire wire = Wire();
  final people = <String>{};
  final links = <String, FakeLink>{};
  bool busy = false;

  Future<Dev> device(String name, {bool member = true}) async {
    final identity = await LocalIdentity.create();
    final node = Node(identity, Store());
    final dev = Dev(node, wire)..name = name;
    wire.devices[identity.device] = dev;
    if (member) people.add(node.person);
    dev.calls = GroupCalls(
      dev,
      members: (s) async =>
          s == space && people.contains(node.person) ? people : null,
      links: ({required device, required iceServers, audio, video}) async {
        final link = FakeLink(device);
        links['$name>${wire.devices[device]!.name}'] = link;
        return link;
      },
      media: FakeMedia.new,
      now: () => wire.clock,
      routing: false,
      otherCallActive: () => busy,
    );
    return dev;
  }

  /// Everyone knows everyone and has just heard from them.
  Future<void> introduce(List<Dev> all) async {
    for (final a in all) {
      for (final b in all) {
        if (a == b) continue;
        await a.node.addContact(b.node.identity.certificate);
        a.lastInbound[b.node.identity.device] = wire.clock;
      }
    }
  }

  Future<void> close() async {
    for (final d in wire.devices.values) {
      await d.calls.close();
      await d.node.close();
    }
  }
}
