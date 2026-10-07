import 'model.dart';
import 'node.dart';

/// What a person last said about who they are connected to.
class FriendList {
  final String id;
  final Set<String> friends;

  /// Their devices when they wrote it, signatures not yet checked.
  final List<DeviceCertificate> devices;
  final int created;
  const FriendList(this.id, this.friends, this.devices, this.created);
}

/// Someone asking this person to connect.
class ConnectRequest {
  final SignedObject object;
  final Json data;
  const ConnectRequest(this.object, this.data);
  String get from => object.author;

  /// The friends it came through, nearest the sender first.
  List<String> get via => (data['via'] as List? ?? const []).cast<String>();
  String? get text => data['text'] as String?;
}

/// The friend graph, and making friends through it.
///
/// Each person publishes who they are connected to as a public `friends`
/// object in `_identity`, passed on like a profile, so anyone who can see
/// someone's name can see their friends: the graph is public by design
/// (signed handoffs already show who passes things to whom). The newest
/// list from its author counts. Builds without it drop the kind.
///
/// Two people are linked when either lists the other and neither, having
/// published a list, leaves the other out. [chain] is the shortest run of
/// links from this person to someone else.
///
/// [request] asks someone this person is not connected to to connect: a
/// private `connect` object for them, encrypted to the devices their list
/// names and relayed (`via`) by the people on the chain between. They
/// [accept] by admitting the sender's devices and answering the same way;
/// the answer admits theirs here. Nothing is admitted without a request
/// this person wrote, so a stranger cannot connect themselves.
class Connections {
  static const listKind = 'friends';
  static const requestKind = 'connect';
  static const listSpace = '_identity';
  static const requestSpace = '_connect';
  static const maxFriends = 1000;

  /// How long a request or answer travels before it lapses.
  static const lifetime = Duration(days: 30);

  /// Longest chain looked for, in links.
  static const maxLinks = 6;

  final Node node;
  Connections(this.node);

  Map<String, FriendList>? _lists;
  Map<String, Set<String>>? _claimedBy;

  /// Called by the node when a friend list is stored.
  void changed() {
    _lists = null;
    _claimedBy = null;
  }

  /// Each person's newest list, read once and kept until one changes.
  Map<String, FriendList> get lists => _lists ??= _load();

  Map<String, FriendList> _load() {
    final result = <String, FriendList>{};
    // Newest first, so the first from each author is theirs now.
    for (final o in node.store.objects(
      kind: listKind,
      space: listSpace,
      limit: 5000,
    )) {
      if (result.containsKey(o.author)) continue;
      if (_parse(o) case final list?) result[o.author] = list;
    }
    return result;
  }

  static FriendList? _parse(SignedObject o) {
    if (!o.isPublic) return null;
    final p = o.data['payload'] as Json;
    if (!validContent(listKind, p)) return null;
    final devices = <DeviceCertificate>[];
    for (final wire in p['devices'] as List) {
      try {
        final c = DeviceCertificate.fromJson(wire as Json);
        if (c.person == o.author) devices.add(c);
      } catch (_) {}
    }
    return FriendList(
      o.id,
      {
        for (final f in (p['friends'] as List).cast<String>())
          if (f != o.author) f,
      },
      devices,
      o.created,
    );
  }

  /// This person's own newest list, without reading anyone else's: it is
  /// checked on every change.
  FriendList? _own() => switch (node.store.objects(
    kind: listKind,
    space: listSpace,
    author: node.person,
    limit: 1,
  )) {
    [final o] => _parse(o),
    _ => null,
  };

  /// People who list [person], for those whose own list is not known.
  Set<String> _claimers(String person) =>
      (_claimedBy ??= () {
        final index = <String, Set<String>>{};
        for (final MapEntry(key: author, value: list) in lists.entries) {
          for (final f in list.friends) {
            (index[f] ??= {}).add(author);
          }
        }
        return index;
      }())[person] ??
      const {};

  /// Whether [person] is someone this person's devices sync with.
  bool isFriend(String person) =>
      person != node.person &&
      !node.forgotten.contains(person) &&
      node.contacts.values.any(
        (c) => c.person == person && !node.revoked.contains(c.device),
      );

  /// The people this person is connected to now.
  Set<String> mine() => {
    for (final c in node.contacts.values)
      if (c.person != node.person &&
          !node.revoked.contains(c.device) &&
          !node.forgotten.contains(c.person) &&
          !node.blocked.contains(c.person))
        c.person,
  };

  /// Who [person] says they are connected to; this person's own friends
  /// for this person.
  Set<String> friendsOf(String person) =>
      person == node.person ? mine() : lists[person]?.friends ?? const {};

  /// Whether [a] and [b] are linked: see the class comment.
  bool linked(String a, String b) {
    if (a == b) return false;
    if (a == node.person) return isFriend(b);
    if (b == node.person) return isFriend(a);
    final ab = friendsOf(a).contains(b), ba = friendsOf(b).contains(a);
    return (ab || ba) &&
        (ab || !lists.containsKey(a)) &&
        (ba || !lists.containsKey(b));
  }

  /// Everyone linked to [person], as far as is known here.
  Set<String> neighbours(String person) => {
    for (final p in {...friendsOf(person), ..._claimers(person)})
      if (!node.blocked.contains(p) && linked(person, p)) p,
  };

  /// The shortest chain of linked people from this person to [person], both
  /// ends included, or null when none of at most [maxLinks] is known. Ties
  /// go to the chain whose names sort first, so it does not jump about.
  List<String>? chain(String person) {
    if (person == node.person) return [person];
    final from = <String, String>{node.person: ''};
    var frontier = [node.person];
    for (var depth = 0; depth < maxLinks && frontier.isNotEmpty; depth++) {
      final next = <String>[];
      for (final p in frontier) {
        for (final n in neighbours(p).toList()..sort()) {
          if (from.containsKey(n)) continue;
          from[n] = p;
          if (n == person) {
            final path = [n];
            for (var at = p; at.isNotEmpty; at = from[at]!) {
              path.add(at);
            }
            return path.reversed.toList();
          }
          next.add(n);
        }
      }
      frontier = next;
    }
    return null;
  }

  /// This person's devices that still have access.
  List<DeviceCertificate> _ownDevices() => [
    node.identity.certificate,
    for (final c in node.contacts.values)
      if (c.person == node.person &&
          c.device != node.identity.device &&
          !node.revoked.contains(c.device))
        c,
  ];

  /// Publishes this person's list when it says less than they know: their
  /// friends and devices, plus whoever the newest list (perhaps from another
  /// of their devices, ahead of this one) has that this device has not
  /// dropped on purpose. Two devices therefore settle on the union rather
  /// than taking turns. Returns null when nothing changed.
  Future<SignedObject?> publish() async {
    final current = _own();
    final friends = {
      ...mine(),
      ...?current?.friends.where(
        (p) =>
            p != node.person &&
            !node.forgotten.contains(p) &&
            !node.blocked.contains(p),
      ),
    };
    if (current == null && friends.isEmpty) return null;
    final devices = {
      for (final c in _ownDevices()) c.device: c,
      for (final c in current?.devices ?? const <DeviceCertificate>[])
        if (!node.revoked.contains(c.device) && c.person == node.person)
          c.device: c,
    };
    if (current != null &&
        current.friends.length == friends.length &&
        current.friends.containsAll(friends) &&
        current.devices.length == devices.length &&
        current.devices.every((c) => devices.containsKey(c.device))) {
      return null;
    }
    return node.publish(listKind, {
      'friends': (friends.toList()..sort()).take(maxFriends).toList(),
      'devices': [for (final c in devices.values.take(32)) c.toJson()],
    }, space: listSpace);
  }

  /// [person]'s devices as far as is known here: admitted ones, else those
  /// their list names and the one that signed their profile.
  Future<List<DeviceCertificate>> devicesOf(String person) async {
    final found = <String, DeviceCertificate>{
      for (final c in node.contacts.values)
        if (c.person == person && !node.revoked.contains(c.device)) c.device: c,
    };
    if (found.isNotEmpty) return found.values.toList();
    for (final c in [
      ...?lists[person]?.devices,
      for (final o in node.store.objects(
        kind: 'profile',
        author: person,
        limit: 1,
      ))
        o.certificate,
    ]) {
      if (c.person == person &&
          !node.revoked.contains(c.device) &&
          !found.containsKey(c.device) &&
          await c.valid()) {
        found[c.device] = c;
      }
    }
    return found.values.toList();
  }

  /// The people a request to [person] travels through: the chain between,
  /// and for a friend of a friend, every friend who knows them, so it
  /// arrives whichever of them is online.
  List<String> route(String person) {
    final links = chain(person);
    if (links == null || links.length < 3) return const [];
    return {
      ...links.sublist(1, links.length - 1),
      if (links.length == 3)
        for (final f in neighbours(node.person).toList()..sort())
          if (linked(f, person)) f,
    }.take(8).toList();
  }

  /// Asks [person] to connect. Throws when no chain reaches them or none of
  /// their devices is known.
  Future<SignedObject> request(String person, {String? text}) async {
    if (person == node.person) throw StateError('That is you');
    if (isFriend(person)) throw StateError('Already connected');
    final via = route(person);
    if (via.isEmpty) throw StateError('No chain of friends reaches them yet');
    final devices = await devicesOf(person);
    if (devices.isEmpty) throw StateError('None of their devices is known yet');
    return node.publish(
      requestKind,
      {
        'type': 'request',
        'devices': [for (final c in _ownDevices()) c.toJson()],
        'via': via,
        if (text != null && text.trim().isNotEmpty) 'text': text.trim(),
      },
      space: requestSpace,
      audience: [person],
      via: via,
      expires: node.now() + lifetime.inMilliseconds,
      recipients: devices,
    );
  }

  /// This person's newest request to [person] still travelling, if any.
  Future<SignedObject?> sentTo(String person) async {
    for (final o in node.store.objects(
      kind: requestKind,
      space: requestSpace,
      author: node.person,
      limit: 200,
    )) {
      if (!o.audience.contains(person) || !node.visible(o)) continue;
      final p = await node.content(o);
      if (p?['type'] == 'request') return o;
    }
    return null;
  }

  /// Requests from people not connected to yet, newest per person.
  Future<List<ConnectRequest>> incoming() async {
    final result = <String, ConnectRequest>{};
    final settled = <String>{};
    for (final o in node.store.objects(
      kind: requestKind,
      space: requestSpace,
      limit: 500,
    )) {
      if (o.author == node.person ||
          o.isPublic ||
          !node.visible(o) ||
          settled.contains(o.author) ||
          isFriend(o.author)) {
        continue;
      }
      final p = await node.content(o);
      if (p == null || p['type'] != 'request') continue;
      settled.add(o.author);
      if (node.store.setting('connectIgnored/${o.id}') == true) continue;
      result[o.author] = ConnectRequest(o, p);
    }
    return result.values.toList();
  }

  /// Hides [request] on this device; the sender is not told.
  void ignore(ConnectRequest request) {
    node.store.set('connectIgnored/${request.object.id}', true);
    node.notify();
  }

  /// Certificates of [person] that [o] and its payload carry.
  List<DeviceCertificate> _carried(SignedObject o, Json p) => [
    if (o.certificate.person == o.author) o.certificate,
    for (final wire in p['devices'] as List? ?? const [])
      if (_certificate(wire) case final c? when c.person == o.author) c,
  ];

  static DeviceCertificate? _certificate(Object? wire) {
    try {
      return DeviceCertificate.fromJson(wire as Json);
    } catch (_) {
      return null;
    }
  }

  Future<int> _admit(List<DeviceCertificate> certificates) async {
    var added = 0;
    for (final c in certificates) {
      if (c.person == node.person ||
          node.revoked.contains(c.device) ||
          node.contacts[c.device]?.signature == c.signature) {
        continue;
      }
      try {
        await node.addContact(c);
        added++;
      } catch (_) {}
    }
    return added;
  }

  /// Connects with whoever sent [request]: admits their devices here, and
  /// answers so theirs admit this person's.
  Future<SignedObject> accept(ConnectRequest request) async {
    await _admit(_carried(request.object, request.data));
    if (!isFriend(request.from)) {
      throw StateError('None of their devices could be added');
    }
    final via = request.via;
    return node.publish(
      requestKind,
      {
        'type': 'accept',
        'request': request.object.id,
        'devices': [for (final c in _ownDevices()) c.toJson()],
        'via': via.reversed.toList(),
      },
      space: requestSpace,
      audience: [request.from],
      via: via,
      expires: node.now() + lifetime.inMilliseconds,
    );
  }

  /// Called by the node when a `connect` object is stored. Admits the
  /// devices of anyone who said yes to a request this person sent, once
  /// each: answers and requests may arrive in either order on any of this
  /// person's devices.
  Future<void> received(SignedObject _) async {
    try {
      await settle();
    } catch (_) {}
  }

  Future<int> settle() async {
    var added = 0;
    for (final o in node.store.objects(
      kind: requestKind,
      space: requestSpace,
      limit: 500,
    )) {
      if (o.author == node.person || o.isPublic || !node.visible(o)) continue;
      if (node.store.setting('connectApplied/${o.id}') == true) continue;
      final p = await node.content(o);
      if (p == null || p['type'] != 'accept') continue;
      final asked = node.store.get(p['request'] as String);
      if (asked == null ||
          asked.author != node.person ||
          !asked.audience.contains(o.author)) {
        continue;
      }
      if ((await node.content(asked))?['type'] != 'request') continue;
      node.store.set('connectApplied/${o.id}', true);
      added += await _admit(_carried(o, p));
    }
    return added;
  }
}
