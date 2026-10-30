import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('who relays', () {
    const good = RelayConditions(mains: true, metered: false);
    ({bool relay, String reason}) decide({
      bool enabled = true,
      bool desktop = true,
      RelayConditions conditions = good,
      bool reachable = true,
    }) => FriendRelayPolicy.decide(
      enabled: enabled,
      supported: true,
      isDesktop: desktop,
      conditions: conditions,
      reachable: reachable,
    );

    test('desktops by default, phones when they opt in', () {
      expect(FriendRelayPolicy.enabled(null, isDesktop: true), isTrue);
      expect(FriendRelayPolicy.enabled(null, isDesktop: false), isFalse);
      expect(FriendRelayPolicy.enabled(true, isDesktop: false), isTrue);
      expect(FriendRelayPolicy.enabled(false, isDesktop: true), isFalse);
    });

    test('pauses on battery, metered networks, savers and unreachability', () {
      expect(decide().relay, isTrue);
      expect(decide(enabled: false).relay, isFalse);
      expect(
        decide(conditions: const RelayConditions(mains: false)).reason,
        contains('battery'),
      );
      // An opted-in phone may relay on battery, but not on mobile data.
      expect(
        decide(
          desktop: false,
          conditions: const RelayConditions(mains: false, metered: false),
        ).relay,
        isTrue,
      );
      expect(
        decide(conditions: const RelayConditions(metered: true)).reason,
        contains('metered'),
      );
      expect(
        decide(conditions: const RelayConditions(saver: true)).reason,
        contains('saver'),
      );
      expect(decide(reachable: false).reason, contains('reach'));
      expect(
        FriendRelayPolicy.decide(
          enabled: true,
          supported: false,
          isDesktop: true,
          conditions: good,
          reachable: true,
        ).relay,
        isFalse,
      );
    });

    test('only public addresses make a device reachable', () {
      expect(FriendRelayPolicy.publicAddress('81.2.3.4:5'), isTrue);
      expect(FriendRelayPolicy.publicAddress('[2001:db8::1]:5'), isTrue);
      expect(FriendRelayPolicy.publicAddress('192.168.1.2:5'), isFalse);
      expect(FriendRelayPolicy.publicAddress('100.70.1.2:5'), isFalse);
      expect(FriendRelayPolicy.publicAddress('127.0.0.1:5'), isFalse);
      expect(FriendRelayPolicy.publicAddress('[fe80::1%3]:5'), isFalse);
      expect(FriendRelayPolicy.publicAddress('[fd00::1]:5'), isFalse);
      expect(FriendRelayPolicy.publicAddress('[::ffff:10.0.0.1]:5'), isFalse);
    });
  });

  test(
    'a device reaches another through a mutual friend that relays',
    () async {
      final a = Node(await LocalIdentity.create(), Store());
      final f = Node(await LocalIdentity.create(), Store());
      final c = Node(await LocalIdentity.create(), Store());
      final na = PeerNetwork(a), nf = PeerNetwork(f), nc = PeerNetwork(c);
      addTearDown(() async {
        for (final n in [na, nf, nc]) {
          await n.stop();
        }
        for (final n in [a, f, c]) {
          await n.close();
        }
      });
      for (final n in [na, nf, nc]) {
        n.relayConditions = () async =>
            const RelayConditions(mains: true, metered: false, reachable: true);
      }
      f.store.set(FriendRelayPolicy.setting, true);
      a.store.set(FriendRelayPolicy.setting, false);
      c.store.set(FriendRelayPolicy.setting, false);
      for (final n in [na, nf, nc]) {
        await n.start(local: true, automatic: false);
      }
      if (!nf.friendRelaySupported) {
        markTestSkipped('iroh library without friend relays');
        return;
      }
      for (final (x, y) in [(na, nf), (nc, nf), (na, nc)]) {
        await x.addCard(y.contactCard());
        await y.addCard(x.contactCard());
      }
      for (final n in [na, nf, nc]) {
        await n.refreshFriendRelay();
      }
      expect(nf.relaying, isTrue, reason: nf.relayStatus);
      expect(na.relaying, isFalse);

      // A and C hear that F relays; F's endpoint learns where they are.
      await na.sync(f.identity.device);
      await nc.sync(f.identity.device);
      expect(na.peerCaps[f.identity.device], contains(FriendRelayPolicy.cap));
      expect(
        FriendRelayPolicy.routes(
          a,
          c.identity.device,
          peerCaps: na.peerCaps,
          lastSync: na.lastSync,
        ),
        [f.identity.device],
      );

      // A has no address for C: only the route through F.
      a.store.set('address/${c.identity.device}', null);
      na.offerFriendsAlways = true;
      final post = await a.publish('post', {'text': 'through F'});
      await na.sync(c.identity.device);
      expect(na.syncErrors, isEmpty, reason: na.events.join('\n'));
      expect(c.store.get(post.id), isNotNull);

      final stats = nf.friendRelayStats()!;
      expect(stats['forwarded'] as int, greaterThan(0));
      expect(
        (stats['senders'] as Map).keys,
        contains(hex(unb64(a.identity.device))),
      );
      expect(na.friendRelayStats()!['sent'] as int, greaterThan(0));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'a friend that does not relay is not offered, and refuses if asked',
    () async {
      final a = Node(await LocalIdentity.create(), Store());
      final f = Node(await LocalIdentity.create(), Store());
      final c = Node(await LocalIdentity.create(), Store());
      final na = PeerNetwork(a), nf = PeerNetwork(f), nc = PeerNetwork(c);
      addTearDown(() async {
        for (final n in [na, nf, nc]) {
          await n.stop();
        }
        for (final n in [a, f, c]) {
          await n.close();
        }
      });
      f.store.set(FriendRelayPolicy.setting, false);
      for (final n in [na, nf, nc]) {
        await n.start(local: true, automatic: false);
      }
      if (!nf.friendRelaySupported) {
        markTestSkipped('iroh library without friend relays');
        return;
      }
      for (final (x, y) in [(na, nf), (nc, nf), (na, nc)]) {
        await x.addCard(y.contactCard());
        await y.addCard(x.contactCard());
      }
      for (final n in [na, nf, nc]) {
        await n.refreshFriendRelay();
      }
      expect(nf.relaying, isFalse);
      expect(nf.relayStatus, 'Off');
      await na.sync(f.identity.device);
      expect(
        na.peerCaps[f.identity.device],
        isNot(contains(FriendRelayPolicy.cap)),
      );
      expect(
        FriendRelayPolicy.routes(
          a,
          c.identity.device,
          peerCaps: na.peerCaps,
          lastSync: na.lastSync,
        ),
        isEmpty,
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
