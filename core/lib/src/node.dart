import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'package:cryptography/cryptography.dart';

import 'model.dart';
import 'store.dart';
import 'blob_worker.dart';

class Node {
  /// Replaced only by [updateIdentity], when this same device seals its root.
  LocalIdentity get identity => _identity;
  LocalIdentity _identity;
  final Store store;
  late final blobs = BlobWorker(store);
  final int Function() now;
  final changes = StreamController<void>.broadcast();
  final Map<String, DeviceCertificate> contacts = {};
  final Set<String> subscriptions = {};
  final Set<String> blocked = {};
  final Set<String> revoked = {};
  Future<void> _publications = Future.value();
  int _pendingPublications = 0;
  bool _closing = false;
  Future<void>? _closeFuture;

  /// Objects a peer may drive this device into storing, in bytes. There is no
  /// limit on how many objects a person's own devices hold: a count cap
  /// bounded nothing real (an object runs up to [maxObjectBytes], so a row
  /// total says little about disk) while it did bound the product. What is
  /// left is the one place an outside party controls growth, measured in the
  /// resource that matters. Reading a view never costs more than the window
  /// it shows, so history beyond this is only ever disk.
  ///
  /// Own writes are never refused by it: a quota on your own data protects
  /// nobody. A device that fills this with its own objects would stop
  /// accepting new ones from peers; objects are metadata and text, with
  /// attachments in blobs, so that is on the order of a million notes, and
  /// `receivedBudget` in settings raises or disables it.
  static const maxReceivedBytes = 512 * 1024 * 1024;
  static const maxObjectBytes = 256 * 1024;

  /// Entries one peer may list in a single inventory page. Bounds a peer's
  /// message, not this device's storage: it never grows with local history.
  static const maxInventoryEntries = 10000;

  /// How much history an unindexed scanning view reads. Distinct from any
  /// storage budget: these are the remaining views that have no cursor.
  static const maxScan = 10000;

  int get _receivedBudget =>
      store.setting('receivedBudget') as int? ?? maxReceivedBytes;
  static const maxEvidence = 128;
  static const maxPageBytes = 1024 * 1024;
  Node(this._identity, this.store, {int Function()? clock})
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
    // Profiles that applied revocations before withdrawal existed.
    if (canonical(store.setting('revokedWithdrawn')) !=
        canonical(revoked.toList()..sort())) {
      _withdrawRevokedEvidence();
    }
  }
  String get person => identity.person;

  /// Swaps in [next]: this device with its root sealed. The device and
  /// agreement keys, and so everything peers know of this device, stay.
  void updateIdentity(LocalIdentity next) {
    if (next.device != identity.device ||
        next.person != identity.person ||
        next.certificate.agreement != identity.certificate.agreement) {
      throw StateError('Not this device');
    }
    _identity = next;
  }
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
  }) {
    if (_closing || _pendingPublications >= 32) {
      return Future.error(
        StateError(
          _closing ? 'Node is closing' : 'Too many pending publications',
        ),
      );
    }
    Future<SignedObject> run() => _publish(
      kind,
      content,
      space: space,
      audience: audience,
      via: via,
      expires: expires,
    );
    if (store.path == null) return run();
    _pendingPublications++;
    final result = _publications.then((_) => run());
    void settled() => _pendingPublications--;
    _publications = result.then<void>(
      (_) => settled(),
      onError: (Object _, StackTrace _) => settled(),
    );
    return result;
  }

  Future<SignedObject> _publish(
    String kind,
    Json content, {
    required String space,
    required List<String> audience,
    required List<String> via,
    required int expires,
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
      'payload': content,
    };
    final object = await _preparePublication(
      data,
      certs,
      await identity.deviceKey.extract(),
      identity.certificate,
      background: store.path != null,
    );
    // Policy may change while cryptography runs on the worker.
    if (revoked.contains(identity.device)) {
      throw StateError('This device has been revoked');
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

  /// [unlocked] is the root from [LocalIdentity.unlockRoot], needed once
  /// this device's root is sealed.
  Future<SignedObject> revoke(String device, {SimpleKeyPair? unlocked}) async {
    final root = unlocked ?? identity.root;
    if (root == null) {
      throw StateError('Enter your recovery phrase to remove a device');
    }
    if (b64((await root.extractPublicKey()).bytes) != person) {
      throw StateError('That root is not this person');
    }
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
      'signature': await sign(proof, root),
      // Binds the device to this person for peers that do not hold it.
      'certificate': target.toJson(),
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
    // A person revokes only their own devices. A device this node cannot bind
    // to the author is left alone rather than rejected, so an honest
    // revocation still travels to the devices that hold the certificate.
    if (!await _ownsDevice(object.author, proof['device'], p['certificate']))
      return;
    if (!revoked.add(proof['device'])) return;
    store.set('revoked', revoked.toList()..sort());
    _withdrawRevokedEvidence();
  }

  /// Whether [device] is certified as [person]'s, by a certificate this node
  /// already admitted or by [wire], the one the revocation carries.
  Future<bool> _ownsDevice(String person, Object? device, Object? wire) async {
    if (device is! String) return false;
    if (contacts[device] case final known?) return known.person == person;
    if (device == identity.device) return person == this.person;
    if (wire is! Json) return false;
    try {
      final certificate = DeviceCertificate.fromJson(wire);
      return certificate.device == device &&
          certificate.person == person &&
          await certificate.valid();
    } catch (_) {
      return false;
    }
  }

  /// Evidence signed by a revoked device, and handoffs or receipts that
  /// depend on it, can no longer be proven. Peers reject it, so it is removed
  /// rather than offered, and inventory digests stay comparable.
  void _withdrawRevokedEvidence() {
    if (revoked.isNotEmpty) {
      final withdrawn = [
        for (final id in store.objectsWithEvidenceFrom(revoked))
          ..._withdrawn(store.evidence(id)),
      ];
      if (withdrawn.isNotEmpty) {
        store.batch(() => store.removeEvidence(withdrawn));
      }
    }
    store.set('revokedWithdrawn', revoked.toList()..sort());
  }

  /// IDs among [records] signed by a revoked device or depending on one.
  Set<String> _withdrawn(Iterable<Evidence> records) {
    final withdrawn = {
      for (final e in records)
        if (revoked.contains(e.certificate.device)) e.id,
    };
    if (withdrawn.isEmpty) return withdrawn;
    for (var changed = true; changed;) {
      changed = false;
      for (final e in records) {
        if (withdrawn.contains(e.id)) continue;
        final depends = e.data['domain'] == 'ournet/receipt/2'
            ? withdrawn.contains(e.data['handoff'])
            : (e.data['parents'] as List? ?? const []).any(withdrawn.contains);
        if (depends) {
          withdrawn.add(e.id);
          changed = true;
        }
      }
    }
    return withdrawn;
  }

  /// Objects one inventory reconciles. History beyond it is covered by later
  /// windows, so an inventory stays a bounded message however much a device
  /// holds. Tests narrow it to walk several windows over a small profile.
  static int inventoryWindow = 2000;

  /// Cursor pages inspect a fixed number of routes, including routes this peer
  /// cannot receive. A sparse sharing policy must not scan the whole profile.
  /// The timestamp bounds still let older peers answer this inventory.
  Json inventoryAfter({String? peerDevice, InventoryCursor? after}) {
    final peer = peerDevice == null ? null : contacts[peerDevice];
    final routes = store.routesAfter(
      after: after == null ? null : (after.created, after.id),
      limit: inventoryWindow + 1,
    );
    final more = routes.length > inventoryWindow;
    final page = routes.take(inventoryWindow).toList();
    final visible = page.where(
      (route) =>
          peerDevice == null ||
          (peer != null && _offerable(route, peer, {route.space})),
    );
    store.primeEvidence([for (final route in visible) route.id]);
    return {
      'version': 2,
      'cursorPaging': true,
      'subscriptions': subscriptions.toList()..sort(),
      'have': {
        for (final route in visible) route.id: store.evidenceDigest(route.id),
      },
      'from': more ? page.last.created : 0,
      if (after != null) 'until': after.created,
      if (after != null) 'after': after.toJson(),
      'more': more,
      if (more)
        'next': InventoryCursor(page.last.created, page.last.id).toJson(),
      if (more)
        'through': InventoryCursor(page.last.created, page.last.id).toJson(),
      'revoked': revoked.toList()..sort(),
      if (peer != null) 'devices': sharedCertificates(peer),
    };
  }

  /// What this device holds, for the [window]th page of history, newest
  /// first. `from` and `until` are the creation times the entries cover:
  /// window 0 reaches above the newest object this device holds, and the last
  /// window reaches below the oldest, so successive windows tile all of
  /// history with no gap. `more` says whether an older window follows.
  Json inventory({String? peerDevice, int window = 0}) {
    final peer = peerDevice == null ? null : contacts[peerDevice];
    // Routes stream out of the store already in this order, so only the
    // window being described is ever held, however much history there is.
    final skip = window * inventoryWindow;
    final page = <ObjectRoute>[];
    ObjectRoute? preceding;
    var offerable = 0;
    var more = false;
    (int, String)? cursor;
    walk:
    while (true) {
      final batch = store.routesAfter(after: cursor);
      if (batch.isEmpty) break;
      for (final route in batch) {
        cursor = (route.created, route.id);
        if (peerDevice != null &&
            !(peer != null && _offerable(route, peer, {route.space})))
          continue;
        if (offerable < skip) {
          preceding = route;
        } else if (page.length < inventoryWindow) {
          page.add(route);
        } else {
          more = true;
          break walk;
        }
        offerable++;
      }
    }
    return {
      'version': 2,
      'subscriptions': subscriptions.toList()..sort(),
      'have': {for (final r in page) r.id: store.evidenceDigest(r.id)},
      // Bounds overlap by an object at each edge, so entries sharing a
      // creation time across a boundary are still covered.
      'from': more ? page.last.created : 0,
      if (preceding != null) 'until': preceding.created,
      'more': more,
      'revoked': revoked.toList()..sort(),
      if (peer != null) 'devices': sharedCertificates(peer),
    };
  }

  static const maxSharedCertificates = 256;

  /// Root-signed certificates a peer may learn: a person's own devices learn
  /// every admitted contact, and friends learn this person's other devices,
  /// so linked devices can read and send the same conversations.
  List<Json> sharedCertificates(DeviceCertificate peer) => [
    for (final c in [identity.certificate, ...contacts.values])
      if (c.device != peer.device &&
          !revoked.contains(c.device) &&
          (peer.person == person ||
              (c.person == person && !blocked.contains(peer.person))))
        c.toJson(),
  ].take(maxSharedCertificates).toList();

  /// Admits certificates shared by [peerDevice] under [sharedCertificates]'
  /// policy. Returns the newly admitted devices.
  Future<List<DeviceCertificate>> learnCertificates(
    String peerDevice,
    Object? shared,
  ) async {
    final peer = contacts[peerDevice];
    if (peer == null || shared is! List) return const [];
    final added = <DeviceCertificate>[];
    for (final wire in shared.take(maxSharedCertificates)) {
      try {
        final c = DeviceCertificate.fromJson(wire as Json);
        final known = contacts[c.device];
        if (c.device == identity.device ||
            revoked.contains(c.device) ||
            (known != null && known.signature == c.signature) ||
            (peer.person != person && c.person != peer.person) ||
            // Keep an existing binding unless the owner re-certified it.
            (known != null && known.person != c.person) ||
            !await c.valid())
          continue;
        contacts[c.device] = c;
        added.add(c);
      } catch (_) {}
    }
    if (added.isNotEmpty) {
      store.set('contacts', contacts.values.map((c) => c.toJson()).toList());
      notify();
    }
    return added;
  }

  bool canOffer(SignedObject o, DeviceCertificate peer, Set<String> wanted) =>
      _offerable(ObjectRoute.of(o), peer, wanted);

  bool _offerable(ObjectRoute o, DeviceCertificate peer, Set<String> wanted) {
    if (blocked.contains(o.author) ||
        revoked.contains(o.device) ||
        (o.expires != 0 && o.expires <= now()))
      return false;
    if (!o.isPublic)
      return o.audience.contains(peer.person) || o.via.contains(peer.person);
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

  /// Signs evidence records together; disk profiles sign in a short-lived
  /// isolate, as publications do, so sync pages do not stall the UI isolate.
  Future<List<Evidence>> _makeEvidence(List<Json> records) async {
    if (records.isEmpty) return const [];
    final key = await identity.deviceKey.extract();
    final certificate = identity.certificate;
    Future<List<Evidence>> signAll() async => [
      for (final data in records)
        Evidence(data, await sign(data, key), certificate)..id,
    ];
    return store.path == null
        ? signAll()
        : Isolate.run(signAll, debugName: 'ournet-evidence');
  }

  /// Pages reconcile evidence independently of object presence. They are
  /// bounded by count AND encoded size. Caller re-exchanges inventory to page.
  Future<List<Json>> offer(String peerDevice, Json inventory) async {
    if (!allowedPeer(peerDevice))
      throw StateError('Peer is not an admitted device');
    if (inventory['version'] != 2) throw StateError('Unsupported protocol');
    await learnCertificates(peerDevice, inventory['devices']);
    final peer = contacts[peerDevice]!;
    final wanted = (inventory['subscriptions'] as List).cast<String>().toSet();
    final have = inventory['have'] as Json;
    if (have.length > maxInventoryEntries || wanted.length > 256)
      throw StateError('Inventory too large');
    // Choose a page first, then sign its new handoffs together off the UI
    // isolate. Handoffs minted for objects that miss this page are reused.
    final page = <SignedObject>[];
    final handoffs = <Json>[];
    final slice = TimeSlice();
    // Only the window the inventory covers: outside it, an absent entry says
    // nothing about what the peer holds. Inventories without a window (older
    // builds) cover everything, as before. The window is walked in bounded
    // pages, so a page is chosen without materialising the whole of it, and
    // all the way to the end of the window: stopping short of it would strand
    // whatever lay beyond, since the next window starts below this one.
    final after = inventory['cursorPaging'] == true
        ? InventoryCursor.parse(inventory['after'])
        : null;
    final through = inventory['cursorPaging'] == true
        ? InventoryCursor.parse(inventory['through'])
        : null;
    (int, String)? cursor = after == null ? null : (after.created, after.id);
    walk:
    while (true) {
      final entries = store.recentEntries(
        from: inventory['from'] as int? ?? 0,
        until: inventory['until'] as int?,
        after: cursor,
        through: through == null ? null : (through.created, through.id),
      );
      if (entries.isEmpty) break;
      // One query for the page's digests: skipping a reconciled object must
      // not cost a lookup, or walking a window the peer already holds would.
      store.primeEvidence([for (final (_, id) in entries) id]);
      await slice.pause();
      for (final (created, id) in entries) {
        cursor = (created, id);
        if (page.length >= 32) break walk;
        // Already reconciled: skip before parsing the object or its evidence.
        if (have[id] == store.evidenceDigest(id)) continue;
        await slice.pause();
        final object = store.get(id);
        if (object == null || !canOffer(object, peer, wanted)) continue;
        final evidence = store.evidence(id);
        // Mint once per target, never on each repeated sync.
        final minted = evidence.any(
          (e) =>
              e.data['domain'] == 'ournet/handoff/2' &&
              e.certificate.device == identity.device &&
              e.data['to'] == peerDevice,
        );
        if (!minted && !have.containsKey(id)) {
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
          handoffs.add({
            'domain': 'ournet/handoff/2',
            'object': id,
            'to': peerDevice,
            'parents': parents.take(1).toList(),
            'created': now(),
          });
        }
        page.add(object);
      }
    }
    final signed = await _makeEvidence(handoffs);
    store.batch(() => signed.forEach(store.putEvidence));
    final out = <Json>[];
    // Budget the encoded list as [receive] measures it: brackets and commas.
    var size = 2;
    for (final object in page) {
      await slice.pause();
      final item = <String, dynamic>{
        'object': object.toJson(),
        'evidence': store.evidence(object.id).map((e) => e.toJson()).toList(),
      };
      final itemSize = bytes(item).length + (out.isEmpty ? 0 : 1);
      if (size + itemSize > maxPageBytes) break;
      size += itemSize;
      out.add(item);
    }
    return out;
  }

  /// Parses a received item once; null when it is malformed.
  static _Received? _parse(dynamic item) {
    try {
      return (
        object: SignedObject.fromJson(item['object']),
        evidence: [
          for (final e in item['evidence'] as List) Evidence.fromJson(e),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  /// Stored records are content-addressed and were verified on arrival, so a
  /// page only sends new objects and evidence to the verifier (null = stored).
  Json _unverified(dynamic item, _Received? parsed) => parsed == null
      ? const {'object': 'malformed'} // Fails verification.
      : {
          'object': store.get(parsed.object.id) == null ? item['object'] : null,
          'evidence': [
            for (final (i, e) in parsed.evidence.indexed)
              store.hasEvidence(parsed.object.id, e.id)
                  ? null
                  : item['evidence'][i],
          ],
        };

  Future<int> receive(String peerDevice, List<dynamic> items) async {
    if (!allowedPeer(peerDevice)) throw StateError('Peer is not admitted');
    if (items.length > 32 || bytes(items).length > maxPageBytes)
      throw StateError('Page quota exceeded');
    // Signature checks depend only on the received records, so the page is
    // verified in a short-lived isolate instead of blocking this one.
    final slice = TimeSlice();
    final parsed = <_Received?>[];
    final unverified = <Json>[];
    for (final item in items) {
      await slice.pause();
      parsed.add(_parse(item));
      unverified.add(_unverified(item, parsed.last));
    }
    final signatures = await _verifySignatures(unverified);
    // Receipts for the page are signed together once its items are stored.
    final receipts = <String, Json>{};
    var changed = 0;
    // Items are independent. A rejected item must not block the rest of the
    // page: offers are deterministic, so the same page would return forever.
    (Object, StackTrace)? rejected;
    for (var index = 0; index < items.length; index++) {
      // Yield only between items; each item's checks and writes stay atomic.
      await slice.pause();
      try {
        changed += await _receiveItem(
          peerDevice,
          parsed[index],
          signatures[index],
          receipts,
        );
      } catch (error, stack) {
        rejected ??= (error, stack);
      }
    }
    // A revocation later in the page may have withdrawn a handoff.
    final signed = await _makeEvidence([
      for (final r in receipts.values)
        if (store.hasEvidence(r['object'], r['handoff'])) r,
    ]);
    changed += store.batch(() => signed.where(store.putEvidence).length);
    if (changed > 0) notify();
    // Report rejection when nothing was accepted, so callers back off.
    if (changed == 0 && rejected != null) {
      Error.throwWithStackTrace(rejected.$1, rejected.$2);
    }
    return changed;
  }

  /// Checks and stores one received item, queueing receipts for its handoffs.
  Future<int> _receiveItem(
    String peerDevice,
    _Received? item,
    (bool, List<bool>) signatures,
    Map<String, Json> receipts,
  ) async {
    if (item == null || !signatures.$1) throw StateError('Invalid object');
    final (object: o, evidence: received) = item;
    if (o.encodedLength > maxObjectBytes) throw StateError('Invalid object');
    if (revoked.contains(o.certificate.device) || blocked.contains(o.author))
      return 0;
    if (o.expires != 0 && o.expires <= now()) return 0;
    if (!o.isPublic &&
        !o.audience.contains(person) &&
        !(o.data['via'] as List).contains(person))
      return 0;
    if (o.isPublic &&
        !['profile', 'revoke'].contains(o.kind) &&
        !subscriptions.contains(o.space) &&
        o.author != person)
      return 0;
    for (final (position, e) in received.indexed) {
      if (e.objectId != o.id || !signatures.$2[position])
        throw StateError('Invalid evidence');
    }
    // Evidence from revoked devices is ignored, not fatal: peers that have not
    // yet learned of the revocation still hold and offer it.
    final stored = store.evidence(o.id);
    final withdrawn = _withdrawn([...stored, ...received]);
    final incoming = [
      for (final e in received)
        if (!withdrawn.contains(e.id)) e,
    ];
    final all = {
      for (final e in stored)
        if (!withdrawn.contains(e.id)) e.id: e,
      for (final e in incoming) e.id: e,
    };
    if (all.length > maxEvidence) throw StateError('Evidence quota exceeded');
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
    if (!held && store.objectBytes >= _receivedBudget)
      throw StateError('Storage budget for received objects reached');
    await applyRevocation(o);
    final changed = store.batch(
      () => [
        store.put(o),
        for (final e in incoming) store.putEvidence(e),
      ].where((added) => added).length,
    );
    if (o.kind == 'read') {
      final payload = await content(o);
      final original = payload == null ? null : store.get(payload['object']);
      if (original != null &&
          original.author == person &&
          original.audience.contains(o.author)) {
        store.set('readBy/${original.id}', o.author);
      }
    }
    for (final h in handoffs) {
      if (all.values.any(
        (e) =>
            e.data['handoff'] == h.id &&
            e.certificate.device == identity.device,
      ))
        continue;
      if (store.evidence(o.id).length >= maxEvidence) break;
      receipts[h.id] = {
        'domain': 'ournet/receipt/2',
        'object': o.id,
        'handoff': h.id,
        'created': now(),
      };
    }
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

  /// Marks every unread message from [peer] read.
  Future<void> markConversationRead(String peer) async {
    while (true) {
      final page = store.unreadMessages(person, peer, limit: 100);
      if (!page.any(visible)) return;
      for (final o in page.where(visible)) {
        await markRead(o.id);
      }
    }
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    if (store.path != null) await _publications;
    try {
      await blobs.close();
    } finally {
      await changes.close();
      store.close();
    }
  }
}

// Only the device signing key and public recipient certificates cross this
// boundary; the root identity and database never leave the owning isolate.
// Node serializes and bounds requests. In-memory stores retain the synchronous
// test path; real disk profiles offload encryption, signing and verification.
Future<SignedObject> _preparePublication(
  Json data,
  List<DeviceCertificate> recipients,
  SimpleKeyPairData key,
  DeviceCertificate certificate, {
  required bool background,
}) {
  Future<SignedObject> prepare() async {
    if ((data['audience'] as List).isNotEmpty) {
      data['payload'] = await encryptFor(data['payload'], recipients);
    }
    final object = SignedObject(data, await sign(data, key), certificate);
    if (!await object.valid()) throw StateError('Invalid object fields');
    if (object.encodedLength > Node.maxObjectBytes) {
      throw StateError('Local object quota reached');
    }
    object.id; // Compute the content hash here too.
    return object;
  }

  return background
      ? Isolate.run(prepare, debugName: 'ournet-publish')
      : prepare();
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
            item['object'] == null ||
                await check(
                  () => SignedObject.fromJson(item['object']).valid(),
                ),
            [
              for (final e in item['evidence'] as List? ?? const [])
                e == null || await check(() => Evidence.fromJson(e).valid()),
            ],
          ),
      ];
    }, debugName: 'ournet-verify');

/// Deterministic integration harness. No sockets, UI or native iroh needed.
Future<int> syncPair(Node a, Node b, {int rounds = 8}) async {
  var total = 0;
  InventoryCursor? afterA, afterB;
  for (var i = 0; i < rounds; i++) {
    final forB = b.inventoryAfter(peerDevice: a.identity.device, after: afterB);
    var changed = await b.receive(
      a.identity.device,
      await a.offer(b.identity.device, forB),
    );
    final forA = a.inventoryAfter(peerDevice: b.identity.device, after: afterA);
    changed += await a.receive(
      b.identity.device,
      await b.offer(a.identity.device, forA),
    );
    total += changed;
    // A quiet window means this slice of history agrees; older windows still
    // need reconciling before the pair is done.
    if (changed == 0) {
      if (forA['more'] != true && forB['more'] != true) break;
      if (forA['more'] == true) afterA = InventoryCursor.parse(forA['next']);
      if (forB['more'] == true) afterB = InventoryCursor.parse(forB['next']);
    }
  }
  return total;
}

typedef _Received = ({SignedObject object, List<Evidence> evidence});

/// Stable position in newest-first routing history. Validate wire cursors
/// before using them in a query; they never authorize sharing an object.
class InventoryCursor {
  final int created;
  final String id;
  const InventoryCursor(this.created, this.id);

  List<Object> toJson() => [created, id];

  static InventoryCursor? parse(Object? value) {
    if (value == null) return null;
    if (value case [
      final int created,
      final String id,
    ] when created >= 0 && RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) {
      return InventoryCursor(created, id);
    }
    throw StateError('Invalid inventory cursor');
  }
}
