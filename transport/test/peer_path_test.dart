import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

void main() {
  final at = DateTime(2026);
  PathKind? kind(String s) => PeerPath.parse(s, at)?.kind;

  test('reads relay and direct addresses from iroh path events', () {
    expect(kind('Relay(https://euc1-1.relay.n0.iroh.link./)'), PathKind.relay);
    expect(
      PeerPath.parse(
        'Relay(https://euc1-1.relay.n0.iroh.link./)',
        at,
      )!.describe(),
      'through relay euc1-1.relay.n0.iroh.link.',
    );
    expect(kind('Ip(192.168.1.20:41641)'), PathKind.lan);
    expect(kind('Ip(10.0.0.5:1)'), PathKind.lan);
    expect(kind('Ip(172.20.1.1:1)'), PathKind.lan);
    expect(kind('Ip(127.0.0.1:1)'), PathKind.lan);
    expect(kind('Ip([fe80::1%3]:1)'), PathKind.lan);
    expect(kind('Ip([fd12::1]:1)'), PathKind.lan);
    expect(kind('Ip(172.32.1.1:1)'), PathKind.direct);
    expect(kind('Ip(81.2.3.4:5)'), PathKind.direct);
    expect(kind('Ip([2001:db8::1]:5)'), PathKind.direct);
    expect(kind('Custom(x)'), isNull);
    final friend = PeerPath.parse(
      'Custom(CustomAddr { id: 1330529874, data: [ababababababababababababababababababababababababababababababababcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd] })',
      at,
    )!;
    expect(friend.kind, PathKind.friend);
    expect(
      friend.address,
      'abababababababababababababababababababababababababababababababab',
    );
    expect(friend.isDirect, isFalse);
    expect(friend.describe(), "through a friend's device");
    expect(
      kind(
        'Custom(CustomAddr { id: 32, data: [abababababababababababababababababababababababababababababababababababababababababababababababababababababababababababababababab] })',
      ),
      isNull,
    );
  });

  test('a direct path says when a relay only helped to connect', () {
    final relay = PeerPath.parse('Relay(https://r.example/)', at)!;
    final direct = PeerPath.parse('Ip(81.2.3.4:5)', at)!;
    expect(
      direct.after(relay).describe(),
      'direct over the internet (relay used to connect)',
    );
    expect(direct.after(relay).toJson()['startedVia'], 'relay');
    expect(direct.after(direct).describe(), 'direct over the internet');
    // Staying on the relay is not "used to connect".
    expect(relay.after(relay).describe(), 'through relay r.example');
    expect(direct.after(null).startedVia, isNull);
  });

  test('counts connections by the path each ended on', () {
    PeerPath path(String s) => PeerPath.parse(s, at)!;
    final relay = path('Relay(https://euc1-1.relay.n0.iroh.link./)');
    final counts = PathCounts()
      ..add(relay, relay)
      ..add(relay, path('Ip(81.2.3.4:5)'))
      ..add(null, path('Ip([2001:db8::1]:5)'))
      ..add(null, path('Ip(192.168.1.20:41641)'))
      ..add(null, path('Ip([fe80::1%3]:1)'))
      ..add(null, null);
    expect(counts.toJson(), {
      'total': 6,
      'lan4': 1,
      'lan6': 1,
      'direct4': 1,
      'direct6': 1,
      'relay': 1,
      'friend': 0,
      'unknown': 1,
      'upgraded': 1,
    });
    expect(relay.isIpv6, isFalse);
  });

  test('relays added in settings come first, n0 always follows', () async {
    final a = Node(await LocalIdentity.create(), Store());
    addTearDown(a.close);
    final network = PeerNetwork(a);
    expect(network.relayUrls, PeerNetwork.n0Relays);
    network.extraRelays = [
      'https://relay.example.com./',
      PeerNetwork.n0Relays.first,
    ];
    expect(network.relayUrls.first, 'https://relay.example.com./');
    expect(network.relayUrls.toSet(), {
      'https://relay.example.com./',
      ...PeerNetwork.n0Relays,
    });
    expect(network.relayUrls.length, PeerNetwork.n0Relays.length + 1);
  });

  test('devices on one network record a direct path to each other', () async {
    final a = Node(await LocalIdentity.create(), Store());
    final b = Node(await LocalIdentity.create(), Store());
    final na = PeerNetwork(a), nb = PeerNetwork(b);
    addTearDown(() async {
      await na.stop();
      await nb.stop();
      await a.close();
      await b.close();
    });
    await na.start(local: true, automatic: false);
    await nb.start(local: true, automatic: false);
    await na.addCard(nb.contactCard());
    await nb.addCard(na.contactCard());
    await na.sync(b.identity.device);
    expect(na.syncErrors, isEmpty, reason: na.events.join('\n'));
    // Path events arrive asynchronously, the last as connections close.
    for (
      var i = 0;
      i < 50 &&
          (na.paths[b.identity.device] == null ||
              nb.paths[a.identity.device] == null);
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(na.paths[b.identity.device]?.isDirect, isTrue);
    expect(nb.paths[a.identity.device]?.isDirect, isTrue);
    expect(na.events.any((e) => e.contains('Path to')), isTrue);
    await na.stop();
    for (var i = 0; i < 50 && nb.connectedTo(a.identity.device); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(na.connectedTo(b.identity.device), isFalse);
    expect(nb.connectedTo(a.identity.device), isFalse);
    // Each closed connection is counted once its last path events are in.
    for (var i = 0; i < 50 && nb.allPathCounts.total == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final counts = nb.pathCounts[a.identity.device]!;
    expect(counts.total, greaterThan(0));
    expect(counts.lan4 + counts.lan6, counts.total);
    expect(nb.allPathCounts.total, counts.total);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'watched devices report a round trip while connected, never dialled',
    () async {
      final a = Node(await LocalIdentity.create(), Store());
      final b = Node(await LocalIdentity.create(), Store());
      final na = PeerNetwork(a), nb = PeerNetwork(b);
      addTearDown(() async {
        await na.stop();
        await nb.stop();
        await a.close();
        await b.close();
      });
      await na.start(local: true, automatic: false);
      await nb.start(local: true, automatic: false);
      await na.addCard(nb.contactCard());
      await nb.addCard(na.contactCard());
      final device = b.identity.device;
      // Never connected: nothing is dialled to measure it.
      final before = na.dialed;
      expect(await na.ping(device), isNull);
      expect(na.dialed, before);

      await na.sync(device);
      expect(na.syncErrors, isEmpty, reason: na.events.join('\n'));
      expect(na.peerCaps[device], contains('ping'));
      final stop = na.watchRtt(device);
      Future<void> waitFor(bool Function() done) async {
        for (var i = 0; i < 100 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      await waitFor(() => na.rttTo(device) != null);
      final rtt = na.rttTo(device);
      expect(rtt, isNotNull, reason: na.events.join('\n'));
      expect(rtt!, lessThan(const Duration(seconds: 1)));
      // Pings keep the one pooled connection open past its idle time.
      final dialed = na.dialed;
      await Future<void>.delayed(PeerNetwork.pooledIdle * 2);
      expect(na.connectedTo(device), isTrue);
      expect(na.rttTo(device), isNotNull);
      expect(na.dialed, dialed);

      stop();
      await waitFor(() => !na.connectedTo(device));
      expect(na.connectedTo(device), isFalse);
      expect(na.rttTo(device), isNull);
      expect(await na.ping(device), isNull);
      expect(na.dialed, dialed);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
