import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'model.dart';
import 'store.dart';
import 'blob_worker.dart';

class Node {
  final LocalIdentity identity;
  final Store store;
  late final blobs = BlobWorker(store);
  final int Function() now;
  final changes = StreamController<void>.broadcast();
  final Map<String, DeviceCertificate> contacts = {};
  final Set<String> subscriptions = {};
  final Set<String> blocked = {};
  final Set<String> revoked = {};
  static const maxObjects = 10000;
  static const maxObjectBytes = 256 * 1024;
  static const maxEvidence = 128;
  Node(this.identity, this.store, {int Function()? clock})
    : now = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    for (final j in (store.setting('contacts') as List? ?? [])) {
      final c = DeviceCertificate.fromJson(j);
      contacts[c.device] = c;
    }
    subscriptions.addAll(
      (store.setting('subscriptions') as List? ?? ['general']).cast<String>(),
    );
    blocked.addAll((store.setting('blocked') as List? ?? []).cast<String>());
    revoked.addAll((store.setting('revoked') as List? ?? []).cast<String>());
  }
  String get person => identity.person;
  void notify() {
    if (!changes.isClosed) changes.add(null);
  }

  Future<void> addContact(DeviceCertificate certificate) async {
    if (!await certificate.valid())
      throw StateError('Invalid device certificate');
    if (revoked.contains(certificate.device))
      throw StateError('Device revoked');
    contacts[certificate.device] = certificate;
    store.set('contacts', contacts.values.map((c) => c.toJson()).toList());
    notify();
  }

  void subscribe(String space, bool enabled) {
    if (enabled) {
      subscriptions.add(space);
    } else {
      subscriptions.remove(space);
    }
    store.set('subscriptions', subscriptions.toList()..sort());
    notify();
  }

  void block(String personId, bool enabled) {
    if (enabled) {
      blocked.add(personId);
    } else {
      blocked.remove(personId);
    }
    store.set('blocked', blocked.toList()..sort());
    notify();
  }

  bool allowedPeer(String device) =>
      contacts.containsKey(device) &&
      !revoked.contains(device) &&
      !blocked.contains(contacts[device]!.person);

  Future<SignedObject> publish(
    String kind,
    Json content, {
    String space = 'general',
    List<String> audience = const [],
    List<String> via = const [],
    int expires = 0,
  }) async {
    if (!validContent(kind, content)) throw StateError('Invalid $kind content');
    if (revoked.contains(identity.device))
      throw StateError('This device has been revoked');
    final recipients = audience.toSet()..add(person);
    final certs = [
      identity.certificate,
      ...contacts.values.where(
        (c) => recipients.contains(c.person) && !revoked.contains(c.device),
      ),
    ];
    for (final p in audience) {
      if (!certs.any((c) => c.person == p))
        throw StateError('No authorised device for recipient');
    }
    final data = <String, dynamic>{
      'domain': 'ournet/object/2',
      'nonce': randomId(),
      'kind': kind,
      'space': space,
      'created': now(),
      'expires': expires,
      'audience': audience.isEmpty ? <String>[] : (recipients.toList()..sort()),
      'via': via.toSet().toList()..sort(),
      'payload': audience.isEmpty ? content : await encryptFor(content, certs),
    };
    final object = SignedObject(
      data,
      await sign(data, identity.deviceKey),
      identity.certificate,
    );
    if (!await object.valid()) throw StateError('Invalid object fields');
    if (bytes(object.toJson()).length > maxObjectBytes ||
        store.count >= maxObjects) {
      throw StateError('Local object quota reached');
    }
    store.put(object);
    notify();
    return object;
  }

  // Objects are immutable, so a successful decryption can be reused. Views
  // rebuild from local history after every change; without this they repeat
  // public-key decryption for every item. Bounded by count and ciphertext size.
  static const _contentLimit = 20000;
  static const _contentBytesLimit = 32 * 1024 * 1024;
  final _contents = LinkedHashMap<String, (Json?, int)>();
  int _contentBytes = 0;

  Future<Json?> content(SignedObject object) async {
    if (!visible(object)) return null;
    if (object.isPublic) {
      final payload = object.data['payload'] as Json;
      return validContent(object.kind, payload) ? payload : null;
    }
    final id = object.id;
    final cached = _contents.remove(id);
    if (cached != null) {
      _contents[id] = cached;
      return cached.$1;
    }
    Json? payload;
    try {
      final plain =
          frozen(await decryptFor(object.data['payload'], identity)) as Json;
      payload = validContent(object.kind, plain) ? plain : null;
    } catch (_) {
      payload = null;
    }
    final wire = object.data['payload'];
    final size = wire is Map && wire['box'] is String
        ? (wire['box'] as String).length
        : 0;
    _contents[id] = (payload, size);
    _contentBytes += size;
    while (_contents.length > _contentLimit ||
        _contentBytes > _contentBytesLimit) {
      final oldest = _contents.keys.first;
      _contentBytes -= _contents.remove(oldest)!.$2;
    }
    return payload;
  }

  bool visible(SignedObject o) =>
      !blocked.contains(o.author) &&
      (o.expires == 0 || o.expires > now()) &&
      (o.isPublic || o.audience.contains(person));

  Future<SignedObject> revoke(String device) async {
    if (identity.root == null)
      throw StateError('Use the identity owner device to revoke devices');
    final target = contacts[device];
    if (target == null || target.person != person)
      throw StateError('Can only revoke your own enrolled device');
    final proof = <String, dynamic>{
      'domain': 'ournet/revoke/2',
      'person': person,
      'device': device,
    };
    final object = await publish('revoke', {
      'proof': proof,
      'signature': await sign(proof, identity.root!),
    }, space: '_identity');
    await applyRevocation(object);
    return object;
  }

  Future<void> applyRevocation(SignedObject object) async {
    if (object.kind != 'revoke' || !object.isPublic) return;
    final p = object.data['payload'] as Json;
    final proof = p['proof'] as Json;
    if (proof['domain'] != 'ournet/revoke/2' ||
        proof['person'] != object.author ||
        !await verify(proof, p['signature'], object.author))
      throw StateError('Invalid revocation');
    revoked.add(proof['device']);
    store.set('revoked', revoked.toList()..sort());
  }

  Json inventory({String? peerDevice}) {
    final evidence = store.evidenceIds();
    final peer = peerDevice == null ? null : contacts[peerDevice];
    return {
      'version': 2,
      'subscriptions': subscriptions.toList()..sort(),
      'have': {
        for (final id in store.ids())
          if (peerDevice == null ||
              (peer != null &&
                  canOffer(store.get(id)!, peer, {store.get(id)!.space})))
            id: hash(evidence[id] ?? const <String>[]),
      },
      'revoked': revoked.toList()..sort(),
    };
  }

  bool canOffer(SignedObject o, DeviceCertificate peer, Set<String> wanted) {
    if (blocked.contains(o.author) ||
        revoked.contains(o.certificate.device) ||
        (o.expires != 0 && o.expires <= now()))
      return false;
    if (!o.isPublic)
      return o.audience.contains(peer.person) ||
          (o.data['via'] as List).contains(peer.person);
    return o.kind == 'revoke' ||
        o.kind == 'profile' ||
        wanted.contains(o.space) ||
        peer.person == person;
  }

  Future<Evidence> makeEvidence(Json data) async => Evidence(
    data,
    await sign(data, identity.deviceKey),
    identity.certificate,
  );

  /// Pages reconcile evidence independently of object presence. They are
  /// bounded by count AND encoded size. Caller re-exchanges inventory to page.
  Future<List<Json>> offer(String peerDevice, Json inventory) async {
    if (!allowedPeer(peerDevice))
      throw StateError('Peer is not an admitted device');
    if (inventory['version'] != 2) throw StateError('Unsupported protocol');
    final peer = contacts[peerDevice]!;
    final wanted = (inventory['subscriptions'] as List).cast<String>().toSet();
    final have = inventory['have'] as Json;
    if (have.length > maxObjects || wanted.length > 256)
      throw StateError('Inventory too large');
    final out = <Json>[];
    var size = 0;
    final evidenceIds = store.evidenceIds();
    final slice = TimeSlice();
    for (final object in store.objects(limit: maxObjects)) {
      // Each object is read and updated without an intervening yield.
      await slice.pause();
      if (!canOffer(object, peer, wanted)) continue;
      // Already reconciled: skip before parsing any evidence records.
      if (have.containsKey(object.id) &&
          hash(evidenceIds[object.id] ?? const <String>[]) == have[object.id]) {
        continue;
      }
      var evidence = store.evidence(object.id);
      final known = have[object.id];
      // Mint once per target, never on each repeated sync.
      final existing = evidence.where(
        (e) =>
            e.data['domain'] == 'ournet/handoff/2' &&
            e.certificate.device == identity.device &&
            e.data['to'] == peerDevice,
      );
      if (existing.isEmpty && !have.containsKey(object.id)) {
        final parents = evidence
            .where(
              (e) =>
                  e.data['domain'] == 'ournet/receipt/2' &&
                  e.certificate.device == identity.device,
            )
            .map((e) => e.id)
            .toList();
        if (object.author != person && parents.isEmpty) continue;
        if (evidence.length >= maxEvidence - 2) continue;
        final handoff = await makeEvidence({
          'domain': 'ournet/handoff/2',
          'object': object.id,
          'to': peerDevice,
          'parents': parents.take(1).toList(),
          'created': now(),
        });
        store.putEvidence(handoff);
        evidence = store.evidence(object.id);
      }
      if (have.containsKey(object.id) &&
          hash(evidence.map((e) => e.id).toList()..sort()) == known)
        continue;
      final item = <String, dynamic>{
        'object': object.toJson(),
        'evidence': evidence.map((e) => e.toJson()).toList(),
      };
      final itemSize = bytes(item).length;
      if (out.length >= 32 || size + itemSize > 1024 * 1024) break;
      size += itemSize;
      out.add(item);
    }
    return out;
  }

  Future<int> receive(String peerDevice, List<dynamic> items) async {
    if (!allowedPeer(peerDevice)) throw StateError('Peer is not admitted');
    if (items.length > 32 || bytes(items).length > 1024 * 1024)
      throw StateError('Page quota exceeded');
    var changed = 0;
    // Signature checks depend only on the received records, so the page is
    // verified in a short-lived isolate instead of blocking this one.
    final signatures = await _verifySignatures(items);
    final slice = TimeSlice();
    for (final (index, item) in items.indexed) {
      // Yield only between items; each item's checks and writes stay atomic.
      await slice.pause();
      final o = SignedObject.fromJson(item['object']);
      if (bytes(o.toJson()).length > maxObjectBytes || !signatures[index].$1)
        throw StateError('Invalid object');
      if (revoked.contains(o.certificate.device) || blocked.contains(o.author))
        continue;
      if (o.expires != 0 && o.expires <= now()) continue;
      if (!o.isPublic &&
          !o.audience.contains(person) &&
          !(o.data['via'] as List).contains(person))
        continue;
      if (o.isPublic &&
          !['profile', 'revoke'].contains(o.kind) &&
          !subscriptions.contains(o.space) &&
          o.author != person)
        continue;
      final incoming = (item['evidence'] as List)
          .map((e) => Evidence.fromJson(e))
          .toList();
      final all = {
        for (final e in store.evidence(o.id)) e.id: e,
        for (final e in incoming) e.id: e,
      };
      if (all.length > maxEvidence) throw StateError('Evidence quota exceeded');
      for (final (position, e) in incoming.indexed) {
        if (e.objectId != o.id ||
            !signatures[index].$2[position] ||
            revoked.contains(e.certificate.device))
          throw StateError('Invalid evidence');
      }
      final verified = <String>{};
      bool path(Evidence e, Set<String> visiting) {
        if (verified.contains(e.id)) return true;
        if (!visiting.add(e.id)) return false;
        bool ok;
        if (e.data['domain'] == 'ournet/receipt/2') {
          final h = all[e.data['handoff']];
          ok =
              h != null &&
              h.data['domain'] == 'ournet/handoff/2' &&
              h.data['to'] == e.certificate.device &&
              path(h, visiting);
        } else {
          final parents = (e.data['parents'] as List).cast<String>();
          ok = parents.isEmpty
              ? e.certificate.person == o.author
              : parents.length == 1 &&
                    all[parents.single] != null &&
                    all[parents.single]!.data['domain'] == 'ournet/receipt/2' &&
                    all[parents.single]!.certificate.device ==
                        e.certificate.device &&
                    path(all[parents.single]!, visiting);
        }
        visiting.remove(e.id);
        if (ok) verified.add(e.id);
        return ok;
      }

      if (all.values.any((e) => !path(e, {})))
        throw StateError('Unproven handoff chain');
      final held = store.get(o.id) != null;
      final handoffs = all.values
          .where(
            (e) =>
                e.data['domain'] == 'ournet/handoff/2' &&
                e.data['to'] == identity.device &&
                e.certificate.device == peerDevice,
          )
          .toList();
      if (!held && handoffs.isEmpty)
        throw StateError('No handoff from authenticated peer');
      if (!held && store.count >= maxObjects)
        throw StateError('Storage quota exceeded');
      await applyRevocation(o);
      if (store.put(o)) changed++;
      if (o.kind == 'read') {
        final payload = await content(o);
        final original = payload == null ? null : store.get(payload['object']);
        if (original != null &&
            original.author == person &&
            original.audience.contains(o.author)) {
          store.set('readBy/${original.id}', o.author);
        }
      }
      for (final e in incoming) {
        if (store.putEvidence(e)) changed++;
      }
      for (final h in handoffs) {
        if (all.values.any(
          (e) =>
              e.data['handoff'] == h.id &&
              e.certificate.device == identity.device,
        ))
          continue;
        if (store.evidence(o.id).length >= maxEvidence) break;
        final receipt = await makeEvidence({
          'domain': 'ournet/receipt/2',
          'object': o.id,
          'handoff': h.id,
          'created': now(),
        });
        if (store.putEvidence(receipt)) changed++;
      }
    }
    if (changed > 0) notify();
    return changed;
  }

  Future<void> markRead(String objectId) async {
    final o = store.get(objectId);
    if (o == null || o.author == person || !visible(o)) return;
    if (store.setting('read/$objectId') == true) return;
    await publish(
      'read',
      {'object': objectId},
      audience: [o.author],
      space: '_messages',
    );
    store.set('read/$objectId', true);
    notify();
  }

  Future<void> close() async {
    try {
      await blobs.close();
    } finally {
      await changes.close();
      store.close();
    }
  }
}

/// Validity of each item's object and evidence records, computed elsewhere.
/// Malformed records are reported invalid; the caller re-parses and rejects.
Future<List<(bool, List<bool>)>> _verifySignatures(List<dynamic> items) =>
    Isolate.run(() async {
      Future<bool> check(Future<bool> Function() valid) async {
        try {
          return await valid();
        } catch (_) {
          return false;
        }
      }

      return [
        for (final item in items)
          (
            await check(() => SignedObject.fromJson(item['object']).valid()),
            [
              for (final e in item['evidence'] as List? ?? const [])
                await check(() => Evidence.fromJson(e).valid()),
            ],
          ),
      ];
    }, debugName: 'ournet-verify');

/// Deterministic integration harness. No sockets, UI or native iroh needed.
Future<int> syncPair(Node a, Node b, {int rounds = 8}) async {
  var total = 0;
  for (var i = 0; i < rounds; i++) {
    var changed = await b.receive(
      a.identity.device,
      await a.offer(b.identity.device, b.inventory()),
    );
    changed += await a.receive(
      b.identity.device,
      await b.offer(a.identity.device, a.inventory()),
    );
    total += changed;
    if (changed == 0) break;
  }
  return total;
}
