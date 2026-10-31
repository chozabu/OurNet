import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// How a call's media travels, in the same four words used everywhere.
enum RouteKind {
  local('Local'),
  direct('Direct'),
  friend('Via a friend'),
  relay('Via relay');

  final String label;
  const RouteKind(this.label);

  static RouteKind? named(Object? name) =>
      values.where((k) => k.name == name).firstOrNull;
}

/// The route WebRTC chose for a call, worked out from its stats.
class CallRoute {
  final RouteKind kind;

  /// A direct route that STUN or hole punching found (not a plain local
  /// address).
  final bool stun;

  /// Media goes as datagrams on an iroh connection (the call shim), because
  /// ICE found nothing better.
  final bool overIroh;

  /// The relay server's name, for [RouteKind.relay].
  final String? relay;
  final int? rttMs;
  const CallRoute(
    this.kind, {
    this.stun = false,
    this.overIroh = false,
    this.relay,
    this.rttMs,
  });

  String get label => kind.label;

  /// One line for the details sheet, such as `Direct (found with STUN)`.
  String get detail {
    final via = overIroh ? ', carried over iroh' : '';
    return switch (kind) {
      RouteKind.local => 'Local network$via',
      RouteKind.direct =>
        stun ? 'Direct (found with STUN)$via' : 'Direct over the internet$via',
      RouteKind.friend => 'Through a friend\'s device$via',
      RouteKind.relay =>
        relay == null ? 'Through a relay$via' : 'Through relay $relay$via',
    };
  }

  bool sameAs(CallRoute? other) =>
      other != null &&
      other.kind == kind &&
      other.stun == stun &&
      other.overIroh == overIroh &&
      other.relay == relay;

  /// Reads the selected candidate pair from WebRTC's [stats]. [shim] is this
  /// call's shim, so a pair to it means media goes over iroh, by
  /// [shimPath]. Null before a pair is chosen.
  static CallRoute? fromStats(
    List<StatsReport> stats, {
    CallShim? shim,
    PeerPath? shimPath,
  }) {
    final byId = {for (final s in stats) s.id: s};
    StatsReport? pair;
    for (final s in stats) {
      final selected = byId[s.values['selectedCandidatePairId']];
      if (s.type == 'transport' && selected != null) {
        pair = selected;
        break;
      }
    }
    pair ??= stats
        .where(
          (s) =>
              s.type == 'candidate-pair' &&
              (s.values['selected'] == true ||
                  s.values['nominated'] == true &&
                      s.values['state'] == 'succeeded'),
        )
        .firstOrNull;
    if (pair == null) return null;
    final local = byId[pair.values['localCandidateId']]?.values ?? const {};
    final remote = byId[pair.values['remoteCandidateId']]?.values ?? const {};
    final seconds = num.tryParse('${pair.values['currentRoundTripTime']}');
    final rtt = seconds == null ? null : (seconds * 1000).round();
    final remoteIp = '${remote['ip'] ?? remote['address'] ?? ''}';
    final remotePort = int.tryParse('${remote['port']}');
    if (shim != null &&
        remotePort == shim.port &&
        remoteIp == shim.address.address) {
      return CallRoute(
        switch (shimPath?.kind) {
          PathKind.lan => RouteKind.local,
          PathKind.direct => RouteKind.direct,
          PathKind.friend => RouteKind.friend,
          PathKind.relay || null => RouteKind.relay,
        },
        overIroh: true,
        relay: shimPath?.kind == PathKind.relay ? shimPath!.relayName : null,
        rttMs: rtt,
      );
    }
    final types = {local['candidateType'], remote['candidateType']};
    if (types.contains('relay')) {
      final url = '${local['url'] ?? ''}';
      return CallRoute(
        RouteKind.relay,
        relay: url.isEmpty ? 'TURN server' : url,
        rttMs: rtt,
      );
    }
    if (types.contains('srflx')) {
      return CallRoute(RouteKind.direct, stun: true, rttMs: rtt);
    }
    // Host or peer-reflexive (learned from the checks themselves, as
    // often on a local network): the address says which.
    final host = remoteIp.contains(':') ? '[$remoteIp]' : remoteIp;
    final public =
        PeerPath.parse('Ip($host:${remotePort ?? 0})', DateTime(0))?.kind ==
        PathKind.direct;
    return public
        ? CallRoute(RouteKind.direct, stun: types.contains('prflx'), rttMs: rtt)
        : CallRoute(RouteKind.local, rttMs: rtt);
  }
}
