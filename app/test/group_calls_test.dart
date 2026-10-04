import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/call_link.dart';
import 'package:ournet/services/group_calls.dart';
import 'support/call_rig.dart';

void main() {
  const space = Rig.space;
  late Rig rig;
  late Wire wire;
  late Map<String, FakeLink> links;

  Future<Dev> device(String name, {bool member = true}) =>
      rig.device(name, member: member);
  Future<void> introduce(List<Dev> all) => rig.introduce(all);
  Future<void> settle() => pumpEventQueue(times: 200);

  setUp(() {
    rig = Rig();
    wire = rig.wire;
    links = rig.links;
  });

  tearDown(() => rig.close());

  test('the first to join starts the call and hosts it', () async {
    final a = await device('a');
    final b = await device('b');
    await introduce([a, b]);
    await a.calls.join(space);
    await settle();
    expect(a.calls.active, isTrue);
    expect(a.calls.isHost, isTrue);
    expect(a.calls.infoFor(space)!.count, 1);
    // The group is told, without ringing: b sees a call it can join.
    final seen = b.calls.infoFor(space)!;
    expect(seen.count, 1);
    expect(seen.host, a.node.identity.device);
    expect(b.calls.active, isFalse);
  });

  test('joiners connect to everyone already in, one offer per pair', () async {
    final a = await device('a');
    final b = await device('b');
    final c = await device('c');
    final watcher = await device('watcher');
    await introduce([a, b, c, watcher]);
    await a.calls.join(space);
    await settle();
    await b.calls.join(space);
    await settle();
    await c.calls.join(space);
    await settle();
    for (final d in [a, b, c]) {
      expect(d.calls.infoFor(space)!.count, 3, reason: d.name);
      expect(d.calls.connected, 2, reason: d.name);
    }
    // Later joiners offer to earlier ones; nobody offers to a later joiner.
    final offered = [
      for (final e in links.entries)
        if (e.value.offers.isNotEmpty) e.key,
    ];
    expect(offered, unorderedEquals(['b>a', 'c>a', 'c>b']));
    // Someone not in the call still sees how many are.
    expect(watcher.calls.infoFor(space)!.count, 3);
    expect(watcher.calls.infoFor(space)!.people, hasLength(3));
    expect(a.calls.participants.first.self, isTrue);
    expect(a.calls.participants, hasLength(3));
  });

  test('a device that was not told still finds the call by asking', () async {
    final a = await device('a');
    final fresh = await device('fresh');
    await introduce([a, fresh]);
    // The announcement never reached it (it had just opened the app).
    wire.down.add(fresh.node.identity.device);
    await a.calls.join(space);
    await settle();
    wire.down.clear();
    expect(fresh.calls.infoFor(space), isNull);
    await fresh.calls.join(space);
    await settle();
    expect(fresh.calls.infoFor(space)!.host, a.node.identity.device);
    expect(a.calls.infoFor(space)!.count, 2);
    expect(a.calls.isHost, isTrue);
    expect(fresh.calls.isHost, isFalse);
  });

  test('when the host leaves the next to have joined hosts', () async {
    final a = await device('a');
    final b = await device('b');
    final c = await device('c');
    final watcher = await device('watcher');
    await introduce([a, b, c, watcher]);
    for (final d in [a, b, c]) {
      await d.calls.join(space);
      await settle();
    }
    await a.calls.leave();
    await settle();
    expect(a.calls.active, isFalse);
    for (final d in [b, c, watcher]) {
      expect(
        d.calls.infoFor(space)!.host,
        b.node.identity.device,
        reason: d.name,
      );
      expect(d.calls.infoFor(space)!.count, 2, reason: d.name);
    }
    expect(b.calls.isHost, isTrue);
    expect(c.calls.connected, 1);
    // The new host admits a newcomer.
    final d = await device('d');
    await introduce([a, b, c, watcher, d]);
    await d.calls.join(space);
    await settle();
    expect(b.calls.infoFor(space)!.count, 3);
    expect(c.calls.infoFor(space)!.count, 3);
  });

  test('the last to leave ends the call for everyone at once', () async {
    final a = await device('a');
    final watcher = await device('watcher');
    await introduce([a, watcher]);
    await a.calls.join(space);
    await settle();
    expect(watcher.calls.infoFor(space), isNotNull);
    await a.calls.leave();
    await settle();
    expect(watcher.calls.infoFor(space), isNull);
    expect(watcher.calls.live, isEmpty);
  });

  test(
    'people outside the group neither hear of the call nor join it',
    () async {
      final a = await device('a');
      final outsider = await device('outsider', member: false);
      await introduce([a, outsider]);
      await a.calls.join(space);
      await settle();
      expect(outsider.calls.infoFor(space), isNull);
      await expectLater(outsider.calls.join(space), throwsA(isA<StateError>()));
      // And what they send is refused.
      await expectLater(
        a.groupCall!(outsider.node.identity.device, {
          'op': 'join',
          'space': space,
          'call': 'x',
        }),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('a call holds at most eight devices', () async {
    final all = <Dev>[];
    for (var i = 0; i < 9; i++) {
      all.add(await device('d$i'));
    }
    await introduce(all);
    for (final d in all.take(8)) {
      await d.calls.join(space);
      await settle();
    }
    await expectLater(all[8].calls.join(space), throwsA(isA<StateError>()));
    expect(all[8].calls.active, isFalse);
    expect(all.first.calls.infoFor(space)!.count, 8);
  });

  test('a silent member is dropped and the host reports it', () async {
    final a = await device('a');
    final b = await device('b');
    final watcher = await device('watcher');
    await introduce([a, b, watcher]);
    await a.calls.join(space);
    await settle();
    await b.calls.join(space);
    await settle();
    expect(watcher.calls.infoFor(space)!.count, 2);
    // b vanishes without saying so.
    wire.down.add(b.node.identity.device);
    wire.clock = wire.clock.add(GroupCalls.ttl + const Duration(seconds: 1));
    await a.calls.tick();
    await settle();
    expect(a.calls.infoFor(space)!.count, 1);
    expect(watcher.calls.infoFor(space)!.count, 1);
  });

  test('members take over if the host disappears', () async {
    final a = await device('a');
    final b = await device('b');
    await introduce([a, b]);
    await a.calls.join(space);
    await settle();
    await b.calls.join(space);
    await settle();
    wire.down.add(a.node.identity.device);
    wire.clock = wire.clock.add(GroupCalls.ttl + const Duration(seconds: 1));
    await b.calls.tick();
    await settle();
    expect(b.calls.isHost, isTrue);
    expect(b.calls.infoFor(space)!.count, 1);
    expect(b.calls.active, isTrue);
  });

  test('a call that is not renewed lapses for those not in it', () async {
    final a = await device('a');
    final watcher = await device('watcher');
    await introduce([a, watcher]);
    await a.calls.join(space);
    await settle();
    wire.down.add(a.node.identity.device);
    wire.clock = wire.clock.add(GroupCalls.ttl + const Duration(seconds: 5));
    expect(watcher.calls.infoFor(space), isNull);
    await watcher.calls.tick();
    expect(watcher.calls.live, isEmpty);
  });

  test('two calls started at once merge into one', () async {
    final a = await device('a');
    final b = await device('b');
    await introduce([a, b]);
    // Neither has heard of the other's call: both start their own.
    wire.down.addAll([a.node.identity.device, b.node.identity.device]);
    await a.calls.join(space);
    await b.calls.join(space);
    wire.down.clear();
    expect(a.calls.isHost && b.calls.isHost, isTrue);
    wire.clock = wire.clock.add(GroupCalls.announceEvery);
    await a.calls.tick();
    await b.calls.tick();
    await settle();
    final winner = [a.calls, b.calls].reduce(
      (x, y) =>
          x.infoFor(space)!.call.compareTo(y.infoFor(space)!.call) < 0 ? x : y,
    );
    final loser = winner == a.calls ? b.calls : a.calls;
    // The host of the call with the higher id announces; the other side moves.
    await (loser == a.calls ? a : b).calls.tick();
    await settle();
    expect(a.calls.infoFor(space)!.call, b.calls.infoFor(space)!.call);
    expect(a.calls.infoFor(space)!.count, 2);
  });

  test('muting and the camera are shown to the others', () async {
    final a = await device('a');
    final b = await device('b');
    await introduce([a, b]);
    await a.calls.join(space);
    await settle();
    await b.calls.join(space);
    await settle();
    b.calls.toggleMute();
    await b.calls.toggleCamera();
    await settle();
    final seen = a.calls.participants.firstWhere((p) => !p.self);
    expect(seen.muted, isTrue);
    expect(seen.video, isTrue);
    expect(links['b>a']!.limits, greaterThan(0));
    await b.calls.toggleCamera();
    await settle();
    expect(a.calls.participants.firstWhere((p) => !p.self).video, isFalse);
  });

  test(
    'a one to one call blocks joining, and leaving frees the microphone',
    () async {
      final a = await device('a');
      await introduce([a]);
      rig.busy = true;
      await expectLater(a.calls.join(space), throwsA(isA<StateError>()));
      rig.busy = false;
      await a.calls.join(space);
      await a.calls.leave();
      expect(a.calls.phase, 'idle');
      await a.calls.join(space);
      expect(a.calls.active, isTrue);
    },
  );

  test('an unreachable host does not stop a device joining', () async {
    final a = await device('a');
    final b = await device('b');
    await introduce([a, b]);
    await a.calls.join(space);
    await settle();
    // b has heard of the call, but a is now unreachable and gone quiet.
    expect(b.calls.infoFor(space), isNotNull);
    wire.down.add(a.node.identity.device);
    await b.calls.join(space);
    await settle();
    expect(b.calls.active, isTrue);
    expect(b.calls.isHost, isTrue);
  });

  test('a failed link is offered again with new candidates', () async {
    final a = await device('a');
    final b = await device('b');
    await introduce([a, b]);
    await a.calls.join(space);
    await settle();
    await b.calls.join(space);
    await settle();
    final link = links['b>a']!;
    link.state = LinkState.reconnecting;
    wire.clock = wire.clock.add(const Duration(seconds: 10));
    await b.calls.tick();
    await settle();
    // Same link, an ICE restart, rather than a new call.
    expect(link.offers, [false, true]);
    expect(link.state, LinkState.connected);
  });
}
