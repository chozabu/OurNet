import 'model.dart';
import 'node.dart';

/// Someone this person exchanges messages with without being friends.
class DistantPeer {
  final String person;

  /// When the newest message either way was written.
  final int latest;

  /// Whether this person has written to them, from any of their devices.
  /// Until then the conversation is a request.
  final bool accepted;
  const DistantPeer(this.person, this.latest, this.accepted);
}

/// Direct messages to people who are not friends, carried by the friends
/// in between.
///
/// A distant message is an ordinary `message` in `_messages`, written to
/// one person and encrypted to the devices their friend list (or profile)
/// names, with `via` the people on the chain between, as a request to
/// connect is (see [Connections.request]). Those people's devices pass it on
/// unread, and the reader's receipt comes back the same way, so the sender
/// learns it was delivered. Nothing is admitted: the two never sync with
/// each other, and every later message travels through friends too.
///
/// Each message carries the sender's device certificates, so the reader can
/// answer even when the sender's friend list has not reached them. An
/// optional `title` makes it read as mail rather than chat.
///
/// Spam is bounded where it starts and along the way: only someone admitted
/// by a person on a chain can reach anyone; a sender may write
/// [maxUnanswered] messages before the other person first answers; and a
/// carrier passes on at most [carriedPerDay] messages a day from each
/// non-friend author. Messages from someone this person has not written to
/// are requests (see [conversations]) until they reply.
class DistantMessages {
  /// Messages a sender may write before the other person first answers.
  static const maxUnanswered = 3;

  /// Objects from one non-friend author a carrier takes in a day.
  static const carriedPerDay = 200;

  /// Longest subject.
  static const maxTitle = 200;

  final Node node;
  DistantMessages(this.node);

  /// Whether messages to [person] travel through friends: someone else,
  /// with none of whose devices this person syncs.
  bool isDistant(String person) =>
      person != node.person && !node.connections.isFriend(person);

  /// The people a message to [person] travels through: the chain between,
  /// or, when none is known here, whoever carried their newest message.
  List<String> route(String person) {
    final route = node.connections.route(person);
    if (route.isNotEmpty) return route;
    for (final o in node.store.conversation(node.person, person, limit: 20)) {
      if (o.author != person) continue;
      final via = [
        for (final p in (o.data['via'] as List).cast<String>())
          if (p != node.person && p != person) p,
      ];
      if (via.isNotEmpty) return via;
    }
    return const [];
  }

  /// [person]'s devices: those [Connections.devicesOf] knows, and those
  /// their messages here carry.
  Future<List<DeviceCertificate>> devicesOf(String person) async {
    final found = {
      for (final c in await node.connections.devicesOf(person)) c.device: c,
    };
    for (final o in node.store.conversation(node.person, person, limit: 20)) {
      if (o.author != person) continue;
      final p = await node.content(o);
      for (final wire in p?['devices'] as List? ?? const []) {
        final c = _certificate(wire);
        if (c != null &&
            c.person == person &&
            !node.revoked.contains(c.device) &&
            !found.containsKey(c.device) &&
            await c.valid()) {
          found[c.device] = c;
        }
      }
      if (found.isNotEmpty) break;
    }
    return found.values.toList();
  }

  static DeviceCertificate? _certificate(Object? wire) {
    try {
      return DeviceCertificate.fromJson(wire as Json);
    } catch (_) {
      return null;
    }
  }

  /// How many more messages this person may write to [person] before they
  /// answer; null when there is no limit (they have answered).
  int? remaining(String person) {
    if (node.store.messagesBy(node.person, person, person) > 0) return null;
    final sent = node.store.messagesBy(
      node.person,
      person,
      node.person,
      limit: maxUnanswered,
    );
    return maxUnanswered - sent;
  }

  /// Writes [content] (a `message` payload) to [person], who is not a
  /// friend. Throws when no chain reaches them, none of their devices is
  /// known, or they have not answered [maxUnanswered] earlier messages.
  Future<SignedObject> send(String person, Json content) async {
    if (!isDistant(person)) throw StateError('Not a distant person');
    if (node.blocked.contains(person)) throw StateError('Blocked');
    if (remaining(person) case final left? when left <= 0) {
      throw StateError('Wait for a reply before sending more');
    }
    final via = route(person);
    if (via.isEmpty) throw StateError('No chain of friends reaches them yet');
    final devices = await devicesOf(person);
    if (devices.isEmpty) throw StateError('None of their devices is known yet');
    return node.publish(
      'message',
      {...content, 'devices': _ownDevices()},
      space: '_messages',
      audience: [person],
      via: via,
      recipients: devices,
    );
  }

  /// This person's devices that still have access, as carried in messages.
  List<Json> _ownDevices() => [
    node.identity.certificate.toJson(),
    for (final c in node.contacts.values)
      if (c.person == node.person &&
          c.device != node.identity.device &&
          !node.revoked.contains(c.device))
        c.toJson(),
  ].take(32).toList();

  /// Conversations with people who are not friends, newest first. Blocked
  /// and disconnected people are left out, and requests hidden with
  /// [ignore] until they write again.
  List<DistantPeer> conversations() => [
    for (final r in node.store.recentConversations(node.person))
      if (isDistant(r.peer) &&
          !node.blocked.contains(r.peer) &&
          !node.forgotten.contains(r.peer))
        if (_peer(r.peer, r.created) case final peer?) peer,
  ];

  DistantPeer? _peer(String person, int latest) {
    final accepted =
        node.store.messagesBy(node.person, person, node.person) > 0;
    if (!accepted) {
      final ignored = node.store.setting('distantIgnored/$person');
      if (ignored is int && latest <= ignored) return null;
    }
    return DistantPeer(person, latest, accepted);
  }

  /// Hides the request from [person] on this device until they write again.
  /// They are not told.
  void ignore(String person) {
    final latest = node.store
        .recentConversations(node.person)
        .where((r) => r.peer == person);
    node.store.set(
      'distantIgnored/$person',
      latest.firstOrNull?.created ?? node.now(),
    );
    node.notify();
  }

  final _carried = <String, (int, int)>{};

  /// Whether this device takes [o], which it is offered as one of the people
  /// in its `via`: always for friends' objects and its own person's, and up
  /// to [carriedPerDay] a day from each other author. Counted in memory: a
  /// restart forgives, which costs little.
  bool mayCarry(SignedObject o) {
    if (o.isPublic ||
        o.author == node.person ||
        o.audience.contains(node.person) ||
        !(o.data['via'] as List).contains(node.person) ||
        node.connections.isFriend(o.author) ||
        node.store.get(o.id) != null) {
      return true;
    }
    final day = node.now() ~/ Duration.millisecondsPerDay;
    final (counted, n) = _carried[o.author] ?? (day, 0);
    final count = counted == day ? n : 0;
    if (count >= carriedPerDay) return false;
    if (_carried.length > 1000) _carried.clear();
    _carried[o.author] = (day, count + 1);
    return true;
  }
}
