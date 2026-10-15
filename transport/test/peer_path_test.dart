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

  test(
    'devices on one network record a direct path to each other',
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
      await na.sync(b.identity.device);
      expect(na.syncErrors, isEmpty, reason: na.events.join('\n'));
      // Path events arrive asynchronously, the last as connections close.
      for (var i = 0;
          i < 50 &&
              (na.paths[b.identity.device] == null ||
                  nb.paths[a.identity.device] == null);
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(na.paths[b.identity.device]?.isDirect, isTrue);
      expect(nb.paths[a.identity.device]?.isDirect, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
