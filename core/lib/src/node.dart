import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'package:cryptography/cryptography.dart';

import 'model.dart';
import 'store.dart';
import 'blob_worker.dart';
import 'locations.dart';
import 'avatars.dart';
import 'connections.dart';
import 'group_access.dart';

/// What a person chose about someone else, kept alike on all their devices.
/// Blocking and disconnecting are independent: each choice settles one of
/// them, except [friend], which settles both.
enum ContactState {
  /// Connected and not blocked: what adding someone again on purpose says.
  friend,

  /// Nothing of theirs is shown or exchanged, but they are remembered.
  blocked,

  /// No longer blocked; a disconnect stays.
  unblocked,

  /// Disconnected: their devices are forgotten. A block stays.
  forgotten,
}

class Node {
  /// Replaced only by [updateIdentity], when this same device seals its root.
  LocalIdentity get identity => _identity;
  LocalIdentity _identity;
  final Store store;
  late final blobs = BlobWorker(store);

  /// Profile pictures, cached per person.
  late final avatars = Avatars(this);

  /// Who is friends with whom, and asking someone new to connect.
  late final connections = Connections(this);

  /// Group keys this device holds and whom each group's objects may reach.
  late final groups = GroupAccess(this);

  /// Last known positions; set up when first asked for.
  Locations get locations =>
      _locations ??= Locations(store, clock: () => now());
  Locations? _locations;
  final int Function() now;
  final changes = StreamController<void>.broadcast();

  /// Fires with [changes], naming the kinds of the objects stored or given
  /// evidence since the previous event. Empty when what changed is not a
  /// stored object (settings, contacts, subscriptions). See [onChangesTo].
  late final changedKinds = StreamController<Set<String>>.broadcast(
    onListen: () => _kindsCursor = store.changeSeq,
  );
  int _kindsCursor = 0;

  /// Kinds that decide what this device can read or see (keys, membership,
  /// revocations, blocks): a change to one concerns every listener.
  static const accessKinds = {
    'keys',
    'room',
    'room_invite',
    'room_leave',
    'revoke',
    'contact_state',
  };

  /// Calls [changed] after changes that may concern objects of [kinds]: those
  /// kinds, [accessKinds], and anything that is not a stored object. Other
  /// stored objects (a delivery receipt, a forum post) do not wake it.
  StreamSubscription<Set<String>> onChangesTo(
    Set<String> kinds,
    void Function() changed,
  ) => changedKinds.stream.listen((now) {
    if (now.isEmpty ||
        now.any((k) => kinds.contains(k) || accessKinds.contains(k))) {
      changed();
    }
  });
  final Map<String, DeviceCertificate> contacts = {};
  final Set<String> subscriptions = {};
  final Set<String> blocked = {};

  /// People this person disconnected from: their devices were forgotten and
  /// are not learned again from others, until one is added on purpose.
  final Set<String> forgotten = {};
  final Set<String> revoked = {};
  Future<void> _publications = Future.value();
  int _pendingPublications = 0;
  bool _closing = false;
  Future<void>? _closeFuture;

  static const maxObjectBytes = 256 * 1024;

  /// Entries one peer may list in a single inventory page. Bounds a peer's
  /// message, not this device's storage: it never grows with local history.
  static const maxInventoryEntries = 10000;

  /// How much history an unindexed scanning view reads. Distinct from any
  /// storage budget: these are the remaining views that have no cursor.
  static const maxScan = 10000;

  /// Evidence records one received item may carry. Peers keeping evidence
  /// per path send the chain to them, so this bounds path depth (about 60
  /// hops), not how many devices an object reaches. Builds before per-path
  /// evidence also hold an object's whole record to it: [_offerWhole].
  static const maxEvidence = 128;

  /// Receipts from an object's readers that two devices on its way back to
  /// the author pass each other, beyond their own: the first by ID, so both
  /// sides choose the same ones and their digests settle.
  static const maxSharedReceipts = 32;
  static const maxPageBytes = 1024 * 1024;
  Node(this._identity, this.store, {int Function()? clock})
    : now = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    for (final c in store.contacts()) {
      contacts[c.device] = c;
    }
    subscriptions.addAll(store.subscribedSpaces());
    blocked.addAll((store.setting('blocked') as List? ?? []).cast<String>());
    forgotten.addAll(
      (store.setting('forgotten') as List? ?? []).cast<String>(),
    );
    revoked.addAll(store.revokedDevices());
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
    if (!changedKinds.isClosed && changedKinds.hasListener) {
      final seq = store.changeSeq;
      final kinds = store.kindsChanged(_kindsCursor, seq);
      _kindsCursor = seq;
      changedKinds.add(kinds);
    }
  }

  /// Admits [certificate]. [explicit] is false where a device is admitted
  /// as a side effect (a shared group's members): that does not reconnect
  /// someone this person disconnected from, while adding them on purpose
  /// (an invitation or contact card) does, on all of this person's devices.
  Future<void> addContact(
    DeviceCertificate certificate, {
    bool explicit = true,
  }) async {
    if (!await certificate.valid())
      throw StateError('Invalid device certificate');
    if (revoked.contains(certificate.device))
      throw StateError('Device revoked');
    contacts[certificate.device] = certificate;
    store.putContact(certificate, now());
    if (explicit &&
        certificate.person != person &&
        forgotten.contains(certificate.person)) {
      await setContactState(certificate.person, ContactState.friend);
    }
    notify();
  }

  /// Blocks, unblocks or disconnects from [other] on every one of this
  /// person's devices: a `contact_state` only they can read, newest wins.
  /// Builds before it ignore it and keep their own block list.
  Future<void> setContactState(String other, ContactState state) async {
    if (other == person) throw StateError('That is you');
    final object = await publish(
      'contact_state',
      {'person': other, 'state': state.name},
      space: '_contacts',
      audience: [person],
    );
    _applyContactState(other, state, object.created);
  }

  void _applyContactState(String other, ContactState state, int at) {
    final states = {...?(store.setting('contactStates') as Map?)};
    // Whether the choice about [flag] made at [at] is the newest one.
    bool newest(String flag) {
      final key = '$other/$flag';
      if (states[key] case final int prior when prior > at) return false;
      states[key] = at;
      return true;
    }

    final block = switch (state) {
      ContactState.blocked => true,
      ContactState.unblocked || ContactState.friend => false,
      ContactState.forgotten => null,
    };
    final forget = switch (state) {
      ContactState.forgotten => true,
      ContactState.friend => false,
      _ => null,
    };
    if (block != null && newest('block')) {
      block ? blocked.add(other) : blocked.remove(other);
    }
    if (forget != null && newest('forget')) {
      if (forget) {
        forgotten.add(other);
        contacts.removeWhere((_, c) => c.person == other);
        store.removeContacts(other);
      } else {
        forgotten.remove(other);
      }
    }
    store.set('contactStates', states);
    store.set('blocked', blocked.toList()..sort());
    store.set('forgotten', forgotten.toList()..sort());
    notify();
  }

  void subscribe(String space, bool enabled) {
    if (enabled) {
      subscriptions.add(space);
    } else {
      subscriptions.remove(space);
    }
    store.setSubscribed(space, enabled, now());
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
    List<DeviceCertificate> recipients = const [],

    /// The group key to seal with, instead of the space's current one: for
    /// copies written ahead of the record that holds a new key.
    GroupKey? seal,
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
      extra: recipients,
      seal: seal,
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
    List<DeviceCertificate> extra = const [],
    GroupKey? seal,
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
      // Devices of someone not admitted here, known from what they published:
      // see [Connections.request].
      for (final c in extra)
        if (recipients.contains(c.person) &&
            !revoked.contains(c.device) &&
            !contacts.containsKey(c.device))
          c,
    ];
    for (final p in audience) {
      if (!certs.any((c) => c.person == p))
        throw StateError('No authorised device for recipient');
    }
    // Written to a whole group: also sealed with its key, for whoever joins.
    var group = audience.isEmpty ? null : seal;
    // A room record is for the whole group, and may be the first to hold its
    // key: it seals itself with the key it carries.
    if (group == null &&
        audience.isNotEmpty &&
        kind == 'room' &&
        content['groupKey'] is Json &&
        validGroupKey(content['groupKey'])) {
      group = groupKeyFrom(content['groupKey'] as Json);
    }
    if (group == null && audience.isNotEmpty && space.startsWith('room2:')) {
      await groups.refresh();
      group = groups.sealFor(space, recipients);
    }
    final data = <String, dynamic>{
      'domain': 'ournet/object/2',
      // Absent on objects from before it; builds that do not know it ignore it.
      'v': 2,
      'sig': signatureAlgorithm,
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
      // Read here: static state does not reach the publishing isolate.
      saltedWraps: WireFormat.saltedWraps,
      group: group,
    );
    // Policy may change while cryptography runs on the worker.
    if (revoked.contains(identity.device)) {
      throw StateError('This device has been revoked');
    }
    store.put(object);
    if (kind == 'avatar') avatars.changed(person);
    if (kind == Connections.listKind) connections.changed();
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
    final encrypted = object.data['payload'];
    if (encrypted is! Json) return null;
    List<int>? granted;
    if (!wrappedFor(encrypted, identity.device)) {
      // Written before this device existed, or before this person joined the
      // group it was written to. Another of this person's devices may since
      // have granted its key, or the group's key opens it; until then nothing
      // is cached, so the object becomes readable as soon as either arrives.
      granted = await _grantedKey(id);
      if (granted == null) {
        final group = groups.key(groupSealOf(encrypted) ?? '');
        if (group != null) {
          try {
            granted = await unsealGroup(encrypted, group);
          } catch (_) {}
        }
      }
      if (granted == null) return null;
    }
    try {
      final plain =
          frozen(
                granted == null
                    ? await decryptFor(encrypted, identity)
                    : await decryptWith(encrypted, granted),
              )
              as Json;
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

  /// Content keys this person's other devices granted this one, by object.
  final _grantedKeys = <String, List<int>>{};

  /// For each object with a grant this device can read, the devices that
  /// grant was also encrypted to: those need no further grant for it.
  final _grantedTo = <String, Set<String>>{};
  int _grantCursor = 0;
  Future<void>? _loadingGrants;

  /// Whether this device can open [o]: it was wrapped for this device, or
  /// another of the person's devices granted the key.
  Future<bool> holdsKeyFor(SignedObject o) async {
    final encrypted = o.data['payload'];
    if (encrypted is! Json) return false;
    return wrappedFor(encrypted, identity.device) ||
        await _grantedKey(o.id) != null;
  }

  /// How many of this person's other devices could not open [o] and have not
  /// been granted its key, as far as this device knows.
  int ownDevicesWithoutKey(SignedObject o) {
    final encrypted = o.data['payload'];
    if (encrypted is! Json) return 0;
    final covered = _grantedTo[o.id] ?? const <String>{};
    return [
      for (final c in contacts.values)
        if (c.person == person &&
            c.device != identity.device &&
            !revoked.contains(c.device) &&
            !covered.contains(c.device) &&
            !wrappedFor(encrypted, c.device))
          c,
    ].length;
  }

  Future<List<int>?> _grantedKey(String id) async {
    if (_grantedKeys[id] case final key?) return key;
    await _readGrants();
    return _grantedKeys[id];
  }

  Future<void> _readGrants() => _loadingGrants ??= _loadGrants().whenComplete(
    () => _loadingGrants = null,
  );

  /// Reads the grants stored since the last look, in insertion order, so
  /// each grant is decrypted once however often unreadable rows are drawn.
  Future<void> _loadGrants() async {
    while (true) {
      final page = store.insertedOfKind(_grantCursor, 'keys');
      if (page.isEmpty) return;
      for (final (rowid, grant) in page) {
        _grantCursor = rowid;
        // Only this person's own devices may hand this device a key, and
        // only in a record addressed to this person alone.
        if (grant.author != person ||
            grant.space != '_keys' ||
            grant.audience.length != 1 ||
            grant.audience.single != person ||
            !visible(grant)) {
          continue;
        }
        try {
          final encrypted = grant.data['payload'] as Json;
          // A grant written before this device existed is unreadable here
          // too; a device that can read its objects grants them afresh.
          if (!wrappedFor(encrypted, identity.device)) continue;
          final p = await decryptFor(encrypted, identity);
          if (!validContent('keys', p)) continue;
          final to = {
            for (final w in (encrypted['wraps'] as List).cast<Json>())
              w['device'] as String,
          };
          for (final k in (p['keys'] as List).cast<Json>()) {
            final id = k['object'] as String;
            _grantedKeys[id] = unb64(k['key'] as String);
            final known = _grantedTo[id];
            _grantedTo[id] = known == null ? to : {...known, ...to};
          }
        } catch (_) {}
      }
    }
  }

  /// Grants this person's other devices the content keys of the private
  /// objects this device can read and one of them cannot.
  ///
  /// A private object is encrypted to the devices its author knew of when it
  /// was written, so a device enrolled later reads none of what came before
  /// it, and a friend who has not yet heard of it keeps writing to the others
  /// alone. Conversations cannot be re-issued as notes and groups are, since a
  /// message is its author's signed words. A grant leaves every object as it
  /// is and hands over only the key that opens it, in records addressed to
  /// this person alone, so authors, times and order are unchanged.
  ///
  /// A pass looks only at what was stored since the previous one: chiefly
  /// messages from friends who have not yet heard of a newer device. With
  /// [history] it walks everything this device holds, for a device that
  /// should read what came before it; whether it should is its owner's
  /// choice, so that is never automatic. Either way a key already granted to
  /// every device is not granted again. [progress] is told how many keys have
  /// been granted so far.
  Future<int> shareKeys({bool history = false, void Function(int)? progress}) {
    final run = _keyWork.then((_) => _shareKeys(history, progress));
    _keyWork = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return run;
  }

  Future<void> _keyWork = Future.value();

  Future<int> _shareKeys(bool history, void Function(int)? progress) async {
    final self = identity.device;
    final own = [
      for (final c in contacts.values)
        if (c.person == person &&
            c.device != self &&
            !revoked.contains(c.device))
          c.device,
    ];
    // Where the previous pass stopped. A profile's first pass starts at the
    // present: what came before is history, handed over only on request.
    final saved =
        store.setting('keyGrantCursor') as int? ?? store.insertionCursor;
    if (own.isEmpty) {
      store.set('keyGrantCursor', store.insertionCursor);
      return 0;
    }
    // The last object examined. An incremental pass saves it only where
    // everything up to it is granted or needs nothing, so an interrupted
    // pass resumes there.
    var last = history ? 0 : saved;
    void save() {
      if (last > (store.setting('keyGrantCursor') as int? ?? 0)) {
        store.set('keyGrantCursor', last);
      }
    }

    await _readGrants();
    final slice = TimeSlice();
    final agreement = await identity.agreementKey.extract();
    var granted = 0;
    var pending = <(String, Json)>[];
    Future<void> flush() async {
      if (pending.isEmpty) return;
      final batch = pending;
      pending = [];
      final keys = await _grantableKeys(
        batch,
        agreement,
        self,
        background: store.path != null,
      );
      if (keys.isNotEmpty) {
        await publish(
          'keys',
          {'keys': keys},
          space: '_keys',
          audience: [person],
        );
        granted += keys.length;
        progress?.call(granted);
      }
      if (!history || last >= saved) save();
    }

    while (true) {
      final page = store.insertedSince(last);
      if (page.isEmpty) break;
      for (final (rowid, object) in page) {
        await slice.pause();
        last = rowid;
        final encrypted = object.data['payload'];
        if (object.isPublic ||
            object.kind == 'keys' ||
            encrypted is! Json ||
            !visible(object) ||
            !wrappedFor(encrypted, self)) {
          continue;
        }
        final covered = _grantedTo[object.id] ?? const <String>{};
        if (own.every((d) => covered.contains(d) || wrappedFor(encrypted, d))) {
          continue;
        }
        pending.add((object.id, encrypted));
        if (pending.length >= maxGrantKeys) await flush();
      }
      if (pending.isEmpty && (!history || last >= saved)) save();
    }
    await flush();
    save();
    await _readGrants();
    return granted;
  }

  bool visible(SignedObject o) =>
      !blocked.contains(o.author) &&
      (!o.hasExpiry || o.expires > now()) &&
      (o.isPublic || o.audience.contains(person) || groups.opens(o));

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
      'sig': signatureAlgorithm,
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

  /// Gives one of this person's devices a new name. A device's certificate
  /// keeps the name it was linked with; the newest `device_name` its owner
  /// published replaces it wherever devices are shown. Builds before this
  /// ignore it and keep showing the certificate's name.
  Future<SignedObject> renameDevice(String device, String label) async {
    label = label.trim();
    if (label.isEmpty || label.length > 100) {
      throw StateError('A device name is 1 to 100 characters');
    }
    final own = device == identity.device || contacts[device]?.person == person;
    if (!own) throw StateError('Can only rename your own devices');
    return publish('device_name', {
      'device': device,
      'label': label,
    }, space: '_identity');
  }

  /// The names devices were given after linking, by device: the newest
  /// `device_name` from each device's owner.
  Map<String, String> deviceNames() {
    final names = <String, String>{};
    for (final o in store.objects(kind: 'device_name')) {
      if (!o.isPublic || !visible(o)) continue;
      final p = o.data['payload'];
      if (p is! Map) continue;
      final (device, label) = (p['device'], p['label']);
      if (device is! String || label is! String || label.isEmpty) continue;
      final owner = device == identity.device
          ? person
          : contacts[device]?.person;
      // Newest first: the first name from the owner wins.
      if (owner == o.author) names.putIfAbsent(device, () => label);
    }
    return names;
  }

  /// When each device last did anything this device knows of: the newest
  /// object it signed, or the last sync with it.
  int? lastSeen(String device) {
    final synced = store.setting('peerHealth');
    final at = synced is Map && synced[device] is Map
        ? synced[device]['synced'] as int?
        : null;
    final wrote = store.lastSignedBy(device);
    if (at == null) return wrote;
    if (wrote == null) return at;
    return at > wrote ? at : wrote;
  }

  /// When each removed device lost access: the earliest revocation of it
  /// this node applied. A device removed before its revocation arrived here
  /// has none.
  Map<String, int> revokedAt() {
    final at = <String, int>{};
    for (final o in store.objects(kind: 'revoke')) {
      final p = o.data['payload'];
      if (p is! Map || p['proof'] is! Map) continue;
      final device = p['proof']['device'];
      if (device is! String || !revoked.contains(device)) continue;
      // Only the owner's own counts; another's is stored but never applied.
      if (o.author != (contacts[device]?.person ?? person)) continue;
      // Newest first: the last one seen is the earliest.
      at[device] = o.created;
    }
    return at;
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
    store.addRevoked(proof['device']);
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

  /// Kinds that change which objects may be offered to whom (group state and
  /// revocations). A change to one of them makes devices compare everything
  /// again rather than only what changed.
  static const policyKinds = {'room', 'room_invite', 'revoke'};

  /// This profile's change log epoch. A backup leaves it out, so a restored
  /// profile starts a new one and what peers recorded of it no longer applies.
  late final String syncEpoch = () {
    final saved = store.setting('syncEpoch');
    if (saved is String) return saved;
    final fresh = randomId();
    store.set('syncEpoch', fresh);
    return fresh;
  }();

  /// The newest entry of this device's change log.
  int get changeSeq => store.changeSeq;

  /// The inventory fields that describe this device's sharing with [peer]
  /// rather than particular objects.
  Json _inventoryHeader(DeviceCertificate? peer) => {
    'version': 2,
    'ownRelay': true,
    'subscriptions': subscriptions.toList()..sort(),
    'revoked': revoked.toList()..sort(),
    if (peer != null) 'devices': sharedCertificates(peer),
    if (peer != null) 'groupKeys': groups.keysFor(peer.person),
  };

  /// Everything besides stored objects that decides what this device offers
  /// [peerDevice] and asks of it, as one digest. While it is unchanged on
  /// both sides, the objects changed since the two last agreed are all that
  /// can differ between them.
  String policyDigest(String peerDevice) => hash({
    'epoch': syncEpoch,
    'peer': peerDevice,
    'header': _inventoryHeader(contacts[peerDevice]),
    'blocked': blocked.toList()..sort(),
  });

  /// The objects changed here after change [since], or null when a full
  /// comparison is needed instead.
  List<ObjectRoute>? changedSince(int since) {
    final changed = store.changedSince(since);
    if (changed == null || changed.any((r) => policyKinds.contains(r.kind))) {
      return null;
    }
    return changed;
  }

  /// An inventory of just those of [routes] that [peerDevice] may receive,
  /// with the fields [inventoryAfter] sends, for a sync of what changed.
  Json changeInventory(String peerDevice, Iterable<ObjectRoute> routes) {
    final peer = contacts[peerDevice]!;
    return _listing(peer, routes);
  }

  /// The header, `have` and `paths` of an inventory listing those of
  /// [routes] that [peer] may receive. `have` values are empty: builds since
  /// per-path evidence (0.2.24) compare only its keys, and `paths`.
  Json _listing(DeviceCertificate? peer, Iterable<ObjectRoute> routes) {
    final visible = [
      for (final route in routes)
        if (peer == null || _offerable(route, peer, {route.space}, relay: true))
          route,
    ];
    store.primeEvidence([for (final route in visible) route.id]);
    return {
      ..._inventoryHeader(peer),
      'have': {for (final route in visible) route.id: ''},
      if (peer != null) 'paths': _pathDigests(visible, peer),
    };
  }

  /// Whether [peerDevice] may be offered any of [routes], so that a change to
  /// them is worth a sync with it. Errs towards yes, as [changeInventory]
  /// lists the same routes.
  bool offersAny(String peerDevice, Iterable<ObjectRoute> routes) {
    final peer = contacts[peerDevice];
    return peer != null &&
        routes.any((r) => _offerable(r, peer, {r.space}, relay: true));
  }

  /// Whether [inventory] from [peerDevice] already holds, path for path,
  /// each of [routes] that this device would offer it.
  /// With [offeredOnly] false, routes this device would not offer count too.
  bool agrees(
    String peerDevice,
    Json inventory,
    Iterable<ObjectRoute> routes, {
    bool offeredOnly = true,
  }) {
    final peer = contacts[peerDevice]!;
    final have = inventory['have'] as Map? ?? const {};
    final paths = inventory['paths'] as Map? ?? const {};
    for (final route in routes) {
      if (offeredOnly && !_offerable(route, peer, {route.space}, relay: true)) {
        continue;
      }
      if (!have.containsKey(route.id) ||
          (paths[route.id] ?? '') != _pathDigest(route, peer)) {
        return false;
      }
    }
    return true;
  }

  /// Answers a `delta` request. [peerDevice] last agreed with this device at
  /// this device's change `since`, when its [policyDigest] was `policy`, and
  /// lists in `changes` what it has changed since. The reply lists this
  /// device's own changes since then (`changes`) and what it holds of the
  /// peer's (`view`), or says `full` when everything must be compared.
  Future<Json> answerDelta(String peerDevice, Json request) async {
    await groups.refresh();
    final since = request['since'];
    final theirs = request['changes'];
    final seq = changeSeq;
    final changed = since is int ? changedSince(since) : null;
    if (changed == null ||
        theirs is! Map ||
        theirs['have'] is! Map ||
        (theirs['have'] as Map).length > maxInventoryEntries ||
        request['policy'] != policyDigest(peerDevice)) {
      return {'full': true};
    }
    final ids = (theirs['have'] as Map).keys.whereType<String>().toList();
    return {
      'seq': seq,
      'policy': policyDigest(peerDevice),
      'changes': changeInventory(peerDevice, changed),
      'view': changeInventory(peerDevice, store.routesOf(ids)),
    };
  }

  /// Objects one inventory reconciles. History beyond it is covered by later
  /// windows, so an inventory stays a bounded message however much a device
  /// holds. Tests narrow it to walk several windows over a small profile.
  static int inventoryWindow = 2000;

  /// Cursor pages inspect a fixed number of routes, including routes this peer
  /// cannot receive. A sparse sharing policy must not scan the whole profile.
  /// `cursorPaging` and the timestamp bounds are what 0.2.27 and 0.2.28 read.
  Json inventoryAfter({String? peerDevice, InventoryCursor? after}) {
    final peer = peerDevice == null ? null : contacts[peerDevice];
    if (peerDevice != null && peer == null) {
      throw StateError('Peer is not an admitted device');
    }
    final routes = store.routesAfter(
      after: after == null ? null : (after.created, after.id),
      limit: inventoryWindow + 1,
    );
    final more = routes.length > inventoryWindow;
    final page = routes.take(inventoryWindow).toList();
    return {
      ..._listing(peer, page),
      'cursorPaging': true,
      'from': more ? page.last.created : 0,
      if (after != null) 'until': after.created,
      if (after != null) 'after': after.toJson(),
      'more': more,
      if (more)
        'next': InventoryCursor(page.last.created, page.last.id).toJson(),
      if (more)
        'through': InventoryCursor(page.last.created, page.last.id).toJson(),
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
            forgotten.contains(c.person) ||
            // Keep an existing binding unless the owner re-certified it.
            (known != null && known.person != c.person) ||
            !await c.valid())
          continue;
        contacts[c.device] = c;
        added.add(c);
      } catch (_) {}
    }
    if (added.isNotEmpty) {
      store.batch(() {
        for (final c in added) {
          store.putContact(c, now());
        }
      });
      notify();
    }
    return added;
  }

  /// [peerKeys], when known, are the group keys the peer said it holds: an
  /// object reaching it only as a group's reader goes only to a device that
  /// can open it. Without them, the group's current key must have sealed it.
  bool canOffer(
    SignedObject o,
    DeviceCertificate peer,
    Set<String> wanted, {
    bool relay = false,
    Set<String>? peerKeys,
  }) {
    final route = ObjectRoute.of(o);
    if (!_offerable(route, peer, wanted, relay: relay)) return false;
    if (route.isPublic ||
        route.audience.contains(peer.person) ||
        route.via.contains(peer.person)) {
      return true;
    }
    final sealed = groupSealOf(o.data['payload'] as Json);
    if (sealed == null) return false;
    return peerKeys == null
        ? groups.current(o.space)?.id == sealed
        : peerKeys.contains(sealed);
  }

  /// [relay] is set when [peer] is one of this person's devices and said it
  /// takes [relayed] objects (`ownRelay` in its inventory).
  bool _offerable(
    ObjectRoute o,
    DeviceCertificate peer,
    Set<String> wanted, {
    bool relay = false,
  }) {
    if (blocked.contains(o.author) ||
        (revoked.contains(o.device) && !_relayable(o, peer, relay)) ||
        (o.hasExpiry && o.expires <= now()))
      return false;
    if (!o.isPublic)
      return o.audience.contains(peer.person) ||
          o.via.contains(peer.person) ||
          groups.reaches(o.space, peer.person);
    // As [receive] accepts them. An own device offered posts from a forum it
    // does not follow drops them, and every later page offered the same ones
    // again, so nothing older than them ever reached it.
    return o.kind == 'revoke' ||
        o.kind == 'profile' ||
        o.kind == 'avatar' ||
        o.kind == Connections.listKind ||
        o.kind == 'device_name' ||
        wanted.contains(o.space) ||
        (peer.person == person && o.author == person);
  }

  /// Devices get removed over the years, and what a removed device wrote is
  /// still this person's own words. Revocation stops a device from being
  /// listened to as a source, so a removed device's work is never taken from
  /// a friend, but this person's own devices may hand each other what they
  /// already hold, or a new device would never read the history written on
  /// the old ones.
  bool _relayable(ObjectRoute o, DeviceCertificate peer, bool relay) =>
      relay && peer.person == person && o.author == person;

  /// The evidence for [o] that this device and [peer] both keep once
  /// reconciled, without the records proving it ([_withProof]): handoffs
  /// between the two and the receipts answering them, and for a private
  /// object its readers' receipts on their way back to its author. A device
  /// thereby holds the chain that brought an object to it and its own
  /// deliveries, not how other copies travelled.
  Set<String> _shared(ObjectRoute o, DeviceCertificate peer) {
    final records = store.evidenceRoutes(o.id);
    final ends = {identity.device, peer.device};
    final signers = {for (final r in records) r.id: r.signer};
    // The author and the carriers it named are upstream of every reader.
    bool upstream(String p) => p == o.author || o.via.contains(p);
    final shared = <String>{};
    final readers = <String>[];
    for (final r in records) {
      final other = r.receipt ? signers[r.target] : r.target;
      if (other != null &&
          other != r.signer &&
          ends.contains(r.signer) &&
          ends.contains(other)) {
        shared.add(r.id);
      } else if (r.receipt &&
          !o.isPublic &&
          r.person != o.author &&
          o.audience.contains(r.person) &&
          ((upstream(person) &&
                  (upstream(peer.person) || peer.person == r.person)) ||
              (upstream(peer.person) && person == r.person))) {
        readers.add(r.id);
      }
    }
    readers.sort();
    return shared..addAll(readers.take(maxSharedReceipts));
  }

  /// Digest of [_shared], which a peer keeping evidence per path compares
  /// with its own: '' when the two share nothing, and otherwise 64 bits, as
  /// a mismatch costs only a re-offer and inventories carry one per object.
  String _pathDigest(ObjectRoute o, DeviceCertificate peer) =>
      store.evidenceMemo(o.id, 'path ${peer.device}', () {
        final shared = _shared(o, peer);
        return shared.isEmpty
            ? ''
            : hash(shared.toList()..sort()).substring(0, 16);
      });

  /// Per-path digests for an inventory, leaving out objects the two share
  /// nothing for.
  Map<String, String> _pathDigests(
    Iterable<ObjectRoute> routes,
    DeviceCertificate peer,
  ) => {
    for (final route in routes)
      if (_pathDigest(route, peer) case final d when d.isNotEmpty) route.id: d,
  };

  /// The records among [all] named by [ids], and every record they depend
  /// on, which a receiver needs to verify them.
  static List<Evidence> _withProof(List<Evidence> all, Set<String> ids) {
    final byId = {for (final e in all) e.id: e};
    final needed = <String>{};
    final pending = [...ids];
    while (pending.isNotEmpty) {
      final e = byId[pending.removeLast()];
      if (e == null || !needed.add(e.id)) continue;
      if (e.data['domain'] == 'ournet/receipt/2') {
        pending.add(e.data['handoff'] as String);
      } else {
        pending.addAll((e.data['parents'] as List).cast<String>());
      }
    }
    return [
      for (final e in all)
        if (needed.contains(e.id)) e,
    ];
  }

  /// [receipts] ordered by the length of the chain proving each, shortest
  /// first, ties by ID.
  static List<String> _shortestFirst(
    List<Evidence> all,
    List<String> receipts,
  ) {
    final length = {
      for (final id in receipts) id: _withProof(all, {id}).length,
    };
    return receipts..sort((a, b) {
      final byLength = length[a]!.compareTo(length[b]!);
      return byLength != 0 ? byLength : a.compareTo(b);
    });
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
  ///
  /// With [only], just those of this device's objects are considered, against
  /// an inventory covering them (a sync of what changed since two devices
  /// last agreed). [truncated] is called when the page is full before every
  /// candidate was considered.
  Future<List<Json>> offer(
    String peerDevice,
    Json inventory, {
    List<String>? only,
    void Function()? truncated,
  }) async {
    if (!allowedPeer(peerDevice))
      throw StateError('Peer is not an admitted device');
    if (inventory['version'] != 2) throw StateError('Unsupported protocol');
    await learnCertificates(peerDevice, inventory['devices']);
    await groups.refresh();
    final peer = contacts[peerDevice]!;
    // Builds without group keys send none, and are offered nothing as a
    // group's reader alone: they would refuse it, and every sync would offer
    // the same refused page again.
    final peerKeys = {
      for (final k in (inventory['groupKeys'] as List? ?? const []).take(1024))
        if (k is String) k,
    };
    // One of this person's own devices that asked for relayed objects.
    final relay = inventory['ownRelay'] == true && peer.person == person;
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
    // nothing about what the peer holds. The window is walked in bounded
    // pages, so a page is chosen without materialising the whole of it, and
    // all the way to the end of the window: stopping short of it would strand
    // whatever lay beyond, since the next window starts below this one.
    final after = InventoryCursor.parse(inventory['after']);
    final through = InventoryCursor.parse(inventory['through']);
    // What the two should share of each object the peer holds, per path.
    final paths = inventory['paths'] as Map? ?? const {};
    if (paths.length > maxInventoryEntries)
      throw StateError('Inventory too large');
    (int, String)? cursor = after == null ? null : (after.created, after.id);
    var listed = false;
    walk:
    while (true) {
      final entries = only != null
          ? (listed ? const <ObjectRoute>[] : store.routesOf(only))
          : store.recentRoutes(
              from: inventory['from'] as int? ?? 0,
              until: inventory['until'] as int?,
              after: cursor,
              through: through == null ? null : (through.created, through.id),
            );
      listed = true;
      if (entries.isEmpty) break;
      // One query for the page's digests: skipping a reconciled object must
      // not cost a lookup, or walking a window the peer already holds would.
      store.primeEvidence([for (final route in entries) route.id]);
      await slice.pause();
      for (final route in entries) {
        final id = route.id;
        cursor = (route.created, id);
        if (page.length >= 32) {
          truncated?.call();
          break walk;
        }
        // Already reconciled: skip before parsing the object or its evidence.
        if (have.containsKey(id) &&
            (paths[id] ?? '') == _pathDigest(route, peer))
          continue;
        await slice.pause();
        final object = store.get(id);
        if (object == null ||
            !canOffer(object, peer, wanted, relay: relay, peerKeys: peerKeys)) {
          continue;
        }
        final evidence = store.evidence(id);
        // Mint once per target, never on each repeated sync.
        final minted = evidence.any(
          (e) =>
              e.data['domain'] == 'ournet/handoff/2' &&
              e.certificate.device == identity.device &&
              e.data['to'] == peerDevice,
        );
        if (!minted && !have.containsKey(id)) {
          // Hand on along the shortest chain this device received it by,
          // so paths stay near the distance between people.
          final parents = _shortestFirst(evidence, [
            for (final e in evidence)
              if (e.data['domain'] == 'ournet/receipt/2' &&
                  e.certificate.device == identity.device)
                e.id,
          ]);
          // Another person's object can be handed on only along a route this
          // device holds a receipt for. When that route went through a
          // device since removed, the receipt is gone; this person's own
          // devices still pass it on without one, signature intact.
          final routed = object.author == person || parents.isNotEmpty;
          if (!routed && !relay) continue;
          // A receiver takes at most [maxEvidence] records with an item;
          // offering a longer path would be refused on every sync.
          if (parents.isNotEmpty &&
              _withProof(evidence, {parents.first}).length + 1 > maxEvidence)
            continue;
          if (routed) {
            handoffs.add({
              'domain': 'ournet/handoff/2',
              'sig': signatureAlgorithm,
              'object': id,
              'to': peerDevice,
              'parents': parents.take(1).toList(),
              'created': now(),
            });
          }
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
      final evidence = _withProof(
        store.evidence(object.id),
        _shared(ObjectRoute.of(object), peer),
      );
      // Refused by the receiver however often it is sent.
      if (evidence.length > maxEvidence) continue;
      final item = <String, dynamic>{
        'object': object.toJson(),
        'evidence': [for (final e in evidence) e.toJson()],
      };
      final itemSize = bytes(item).length + (out.isEmpty ? 0 : 1);
      if (size + itemSize > maxPageBytes) {
        truncated?.call();
        break;
      }
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
    await groups.refresh();
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
    // Handed over by one of this person's own devices: see [_relayable].
    final own = contacts[peerDevice]?.person == person;
    if ((revoked.contains(o.certificate.device) &&
            !(own && o.author == person)) ||
        blocked.contains(o.author)) {
      return 0;
    }
    if (o.hasExpiry && o.expires <= now()) return 0;
    if (!o.isPublic &&
        !o.audience.contains(person) &&
        !(o.data['via'] as List).contains(person)) {
      // Written to a group before this person joined it: taken when this
      // device holds the key it is sealed with. The key may have arrived
      // earlier in this same page.
      if (!groups.opens(o)) await groups.learn();
      if (!groups.opens(o)) return 0;
    }
    if (o.isPublic &&
        ![
          'profile',
          'avatar',
          'revoke',
          'device_name',
          Connections.listKind,
        ].contains(o.kind) &&
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
    // A path, not everything every holder knows: stored records may number
    // more, one per delivery this device made, but one item is bounded.
    if (received.length > maxEvidence)
      throw StateError('Evidence quota exceeded');
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

    // Stored records were proven when they arrived.
    if (incoming.any((e) => !path(e, {})))
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
    if (!held && handoffs.isEmpty && !own) {
      throw StateError('No handoff from authenticated peer');
    }
    // What a peer may drive this device into storing is bounded by the
    // storage limit, objects and files together. Own writes never are: a
    // quota on your own data protects nobody.
    if (!held && store.storedBytes >= store.storageLimit)
      throw StateError('Storage limit reached');
    await applyRevocation(o);
    final changed = store.batch(
      () => [
        store.put(o),
        for (final e in incoming) store.putEvidence(e),
      ].where((added) => added).length,
    );
    if (o.kind == 'avatar') avatars.changed(o.author);
    if (o.kind == Connections.listKind) connections.changed();
    if (o.kind == Connections.requestKind) await connections.received(o);
    if (o.kind == 'read') {
      final payload = await content(o);
      final ids = <Object?>{
        if (payload != null) ...[
          payload['object'],
          ...?(payload['objects'] as List?),
        ],
      };
      for (final id in ids.whereType<String>()) {
        final original = store.get(id);
        if (original != null &&
            original.author == person &&
            original.audience.contains(o.author)) {
          store.set('readBy/${original.id}', o.author);
        }
      }
    }
    if (o.kind == 'contact_state' && o.author == person) {
      final payload = await content(o);
      final state = ContactState.values.asNameMap()[payload?['state']];
      if (payload?['person'] case final String other
          when state != null && other != person) {
        _applyContactState(other, state, o.created);
      }
    }
    if (o.kind == 'room_read' && o.author == person) {
      final payload = await content(o);
      if (payload != null) {
        _applyRoomRead(payload['space'] as String, payload['upTo'] as int);
      }
    }
    for (final h in handoffs) {
      if (all.values.any(
        (e) =>
            e.data['handoff'] == h.id &&
            e.certificate.device == identity.device,
      ))
        continue;
      receipts[h.id] = {
        'domain': 'ournet/receipt/2',
        'sig': signatureAlgorithm,
        'object': o.id,
        'handoff': h.id,
        'created': now(),
      };
    }
    return changed;
  }

  Future<void> markRead(String objectId) => markManyRead([objectId]);

  /// Marks messages read with one receipt per author, rather than one per
  /// message. The newest is also named alone, for builds that read only that.
  Future<void> markManyRead(Iterable<String> objectIds) async {
    final byAuthor = <String, List<SignedObject>>{};
    for (final id in objectIds.toSet()) {
      final o = store.get(id);
      if (o == null || o.author == person || !visible(o)) continue;
      if (store.setting('read/$id') == true) continue;
      (byAuthor[o.author] ??= []).add(o);
    }
    for (final MapEntry(key: author, value: all) in byAuthor.entries) {
      all.sort((a, b) => b.created.compareTo(a.created));
      for (var start = 0; start < all.length; start += 200) {
        final page = all.skip(start).take(200).toList();
        await publish(
          'read',
          {
            'object': page.first.id,
            if (page.length > 1) 'objects': [for (final o in page) o.id],
          },
          audience: [author],
          space: '_messages',
        );
        store.batch(() {
          for (final o in page) {
            store.set('read/${o.id}', true);
          }
        });
      }
    }
    if (byAuthor.isNotEmpty) notify();
  }

  /// Marks everything in a private group up to [upTo] (all of it, when null)
  /// read, and tells this person's other devices. Returns once the local marks
  /// are set; the announcement follows.
  Future<void> markRoomRead(String space, {int? upTo}) {
    var newest = 0;
    final marked = _applyRoomRead(space, upTo, newest: (c) => newest = c);
    return marked == 0
        ? Future.value()
        : publish(
            'room_read',
            {'space': space, 'upTo': newest},
            space: '_inbox',
            audience: [person],
          ).then<void>((_) {});
  }

  /// Sets the local read marks for [space] and returns how many were new.
  int _applyRoomRead(String space, int? upTo, {void Function(int)? newest}) {
    var count = 0, latest = 0;
    store.batch(() {
      for (final o in store.allOf(kinds: ['room_item'], space: space)) {
        if (upTo != null && o.created > upTo) continue;
        if (o.created > latest) latest = o.created;
        if (o.author == person || store.setting('seen/${o.id}') == true) {
          continue;
        }
        store.set('seen/${o.id}', true);
        count++;
      }
    });
    newest?.call(latest);
    if (count > 0) notify();
    return count;
  }

  /// Marks every unread message from [peer] read.
  Future<void> markConversationRead(String peer) async {
    while (true) {
      final page = store.unreadMessages(person, peer, limit: 200);
      if (!page.any(visible)) return;
      await markManyRead(page.where(visible).map((o) => o.id));
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
      await changedKinds.close();
      await _locations?.close();
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
  required bool saltedWraps,
  GroupKey? group,
}) {
  Future<SignedObject> prepare() async {
    if ((data['audience'] as List).isNotEmpty) {
      data['payload'] = await encryptFor(
        data['payload'],
        recipients,
        saltedWraps: saltedWraps,
        group: group,
      );
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

/// The content keys of [batch] this device can open, as grant entries.
/// Opening a wrap is a key agreement per object, so disk profiles do it in a
/// short-lived isolate that captures nothing but the batch and the key.
Future<List<Json>> _grantableKeys(
  List<(String, Json)> batch,
  SimpleKeyPairData agreement,
  String device, {
  required bool background,
}) {
  Future<List<Json>> unwrap() async => [
    for (final (id, encrypted) in batch)
      if (await _tryUnwrap(encrypted, agreement, device) case final key?)
        {'object': id, 'key': b64(key)},
  ];
  return background ? Isolate.run(unwrap, debugName: 'ournet-grant') : unwrap();
}

Future<List<int>?> _tryUnwrap(
  Json encrypted,
  SimpleKeyPairData agreement,
  String device,
) async {
  try {
    return await unwrapFor(encrypted, agreement, device);
  } catch (_) {
    return null;
  }
}

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
