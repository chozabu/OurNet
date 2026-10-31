import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ournet/services/call_route.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// WebRTC's stats for a selected pair between [local] and [remote]
/// candidates, found through the transport report as libwebrtc gives it.
List<StatsReport> pair(
  Map<String, Object?> local,
  Map<String, Object?> remote,
) => [
  StatsReport('T', 'transport', 0, {'selectedCandidatePairId': 'P'}),
  StatsReport('P', 'candidate-pair', 0, {
    'localCandidateId': 'L',
    'remoteCandidateId': 'R',
    'currentRoundTripTime': 0.042,
  }),
  // Another pair that is not the one in use.
  StatsReport('Q', 'candidate-pair', 0, {
    'localCandidateId': 'L',
    'remoteCandidateId': 'X',
  }),
  StatsReport('L', 'local-candidate', 0, local),
  StatsReport('R', 'remote-candidate', 0, remote),
];

void main() {
  test('host candidates on a private network are local', () {
    final route = CallRoute.fromStats(
      pair(
        {'candidateType': 'host', 'ip': '192.168.1.4', 'port': 5000},
        {'candidateType': 'host', 'ip': '192.168.1.9', 'port': 6000},
      ),
    )!;
    expect(route.kind, RouteKind.local);
    expect(route.label, 'Local');
    expect(route.rttMs, 42);
    // Peer-reflexive on a local network is still local.
    expect(
      CallRoute.fromStats(
        pair(
          {'candidateType': 'host', 'ip': '192.168.1.4', 'port': 5000},
          {'candidateType': 'prflx', 'ip': '192.168.1.9', 'port': 6000},
        ),
      )!.kind,
      RouteKind.local,
    );
  });

  test('a route STUN found is direct, and says so', () {
    final route = CallRoute.fromStats(
      pair(
        {'candidateType': 'srflx', 'ip': '81.2.3.4', 'port': 5000},
        {'candidateType': 'srflx', 'ip': '90.1.2.3', 'port': 6000},
      ),
    )!;
    expect(route.kind, RouteKind.direct);
    expect(route.stun, isTrue);
    expect(route.detail, 'Direct (found with STUN)');
    final ipv6 = CallRoute.fromStats(
      pair(
        {'candidateType': 'host', 'ip': '2001:db8::1', 'port': 5000},
        {'candidateType': 'host', 'ip': '2001:db8::2', 'port': 6000},
      ),
    )!;
    expect(ipv6.kind, RouteKind.direct);
    expect(ipv6.stun, isFalse);
  });

  test('a TURN candidate is a relay', () {
    final route = CallRoute.fromStats(
      pair(
        {
          'candidateType': 'relay',
          'ip': '5.6.7.8',
          'port': 3478,
          'url': 'turn:turn.example.org',
        },
        {'candidateType': 'srflx', 'ip': '90.1.2.3', 'port': 6000},
      ),
    )!;
    expect(route.kind, RouteKind.relay);
    expect(route.overIroh, isFalse);
    expect(route.detail, 'Through relay turn:turn.example.org');
  });

  test('a pair to the call shim is media over iroh, on its path', () {
    final shim = CallShim(InternetAddress('192.168.1.4'), 4000);
    final stats = pair(
      {'candidateType': 'host', 'ip': '192.168.1.4', 'port': 5000},
      {'candidateType': 'host', 'ip': '192.168.1.4', 'port': 4000},
    );
    final relayed = CallRoute.fromStats(
      stats,
      shim: shim,
      shimPath: PeerPath.parse(
        'Relay(https://euc1-1.relay.n0.iroh.link./)',
        DateTime(2026),
      ),
    )!;
    expect(relayed.kind, RouteKind.relay);
    expect(relayed.overIroh, isTrue);
    expect(
      relayed.detail,
      'Through relay euc1-1.relay.n0.iroh.link., carried over iroh',
    );
    final direct = CallRoute.fromStats(
      stats,
      shim: shim,
      shimPath: PeerPath.parse('Ip(81.2.3.4:5)', DateTime(2026)),
    )!;
    expect(direct.kind, RouteKind.direct);
    expect(direct.detail, 'Direct over the internet, carried over iroh');
    expect(direct.sameAs(relayed), isFalse);
  });

  test('without a selected pair there is no route yet', () {
    expect(CallRoute.fromStats([]), isNull);
    expect(
      CallRoute.fromStats([
        StatsReport('P', 'candidate-pair', 0, {'state': 'in-progress'}),
      ]),
      isNull,
    );
  });
}
