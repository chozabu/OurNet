import 'dart:convert';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

/// Records the requests a device sends and how large they are.
class Recording extends PeerNetwork {
  Recording(super.node);
  final sent = <(String, int)>[];
  @override
  Future<Json> request(String device, Json request) {
    sent.add((
      request['type'] as String,
      utf8.encode(jsonEncode(request)).length,
    ));
    return super.request(device, request);
  }

  List<String> get types => [for (final (t, _) in sent) t];
  int get bytes => sent.fold(0, (n, s) => n + s.$2);
}

Future<(Node, Node, Recording, PeerNetwork)> pair() async {
  final a = Node(await LocalIdentity.create(), Store());
  final b = Node(await LocalIdentity.create(), Store());
  final na = Recording(a), nb = PeerNetwork(b);
  await na.start(local: true, automatic: false);
  await nb.start(local: true, automatic: false);
  await na.addCard(nb.contactCard());
  await nb.addCard(na.contactCard());
  return (a, b, na, nb);
}

void main() {
  late Node a, b;
  late Recording na;
  late PeerNetwork nb;
  setUp(() async => (a, b, na, nb) = await pair());
  tearDown(() async {
    await na.stop();
    await nb.stop();
    await a.close();
    await b.close();
  });

  Future<void> agree() async {
    final peer = b.identity.device;
    await na.sync(peer);
    await na.sync(peer);
    na.sent.clear();
  }

  test('devices that agree exchange one small request', () async {
    for (var i = 0; i < 40; i++) {
      await a.publish('message', {'text': 'Old $i'}, audience: [b.person]);
      await b.publish('message', {'text': 'Reply $i'}, audience: [a.person]);
    }
    await agree();
    await na.sync(b.identity.device);
    expect(na.types, ['delta']);
    expect(na.bytes, lessThan(4096));
    expect(na.syncErrors, isEmpty);
  });

  test('changes on either side arrive through the short exchange', () async {
    await a.publish('message', {'text': 'Before'}, audience: [b.person]);
    await agree();
    final mine = await a.publish(
      'message',
      {'text': 'New'},
      audience: [b.person],
    );
    final theirs = await b.publish(
      'message',
      {'text': 'Theirs'},
      audience: [a.person],
    );
    await na.sync(b.identity.device);
    expect(na.types.first, 'delta');
    expect(b.store.get(mine.id), isNotNull);
    expect(a.store.get(theirs.id), isNotNull);
    // Receipts go back, and then the two agree again.
    na.sent.clear();
    await na.sync(b.identity.device);
    await na.sync(b.identity.device);
    na.sent.clear();
    await na.sync(b.identity.device);
    expect(na.types, ['delta']);
    expect(
      a.store.evidence(mine.id).map((e) => e.data['domain']),
      contains('ournet/receipt/2'),
    );
  });

  test('the peer subscribing to a forum brings its older posts', () async {
    final post = await a.publish('post', {
      'text': 'Posted before they followed',
    }, space: 'forum-x');
    await agree();
    expect(b.store.get(post.id), isNull);
    b.subscribe('forum-x', true);
    await na.sync(b.identity.device);
    // What the peer may be offered changed: compared in full.
    expect(na.types.first, 'delta');
    expect(na.types, contains('pull'));
    expect(b.store.get(post.id), isNotNull);
  });

  test('a change to what may be shared falls back to a full sync', () async {
    await a.publish('message', {'text': 'Before'}, audience: [b.person]);
    await agree();
    a.subscribe('another-forum', true);
    await na.sync(b.identity.device);
    expect(na.types, isNot(contains('delta')));
    expect(na.syncErrors, isEmpty);
    na.sent.clear();
    await na.sync(b.identity.device);
    na.sent.clear();
    await na.sync(b.identity.device);
    expect(na.types, ['delta']);
  });

  test('marks survive a restart of the network', () async {
    await a.publish('message', {'text': 'Before'}, audience: [b.person]);
    await agree();
    await na.stop();
    final again = Recording(a);
    try {
      await again.start(local: true, automatic: false);
      // Capabilities are learnt from the first exchange after a restart.
      await again.sync(b.identity.device);
      again.sent.clear();
      await again.sync(b.identity.device);
      expect(again.types, ['delta']);
    } finally {
      await again.stop();
    }
  });
}
