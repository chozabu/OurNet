import 'model.dart';
import 'node.dart';
import 'note_state.dart';
import 'public_chats.dart';
import 'public_names.dart';

/// A public forum or chat that friends follow, as Browse shows it.
typedef Listing = ({
  String space,

  /// `forum` or `chat`.
  String type,
  String name,
  String description,

  /// The friends who advertise it.
  Set<String> people,

  /// When the newest advert for it was written.
  int newest,
});

/// Finding public forums and chats without being sent an address.
///
/// Following a public forum or chat is private state, so nothing showed what
/// was out there. Each person's devices now publish a small signed `listing`
/// for every public space they follow, unless they turned that off for the
/// space, and Browse shows what friends follow with a count. A listing is
/// offered only by the person who wrote it, never relayed on by friends, so
/// it reaches friends and goes no further: one person cannot flood a stranger
/// with spaces, and the one who advertises is always someone you know. The
/// friend who advertises a space follows it, so subscribing to it from here
/// is also how its posts reach you. Listings expire after 30 days and are
/// renewed after 10 while still followed.
///
/// A device takes part by following the internal space [home]; builds
/// without this are never offered a listing, and do not follow it.
class Listings {
  static const kind = 'listing';
  static const home = '_listing';
  static const lifetime = Duration(days: 30);
  static const refreshAfter = Duration(days: 10);
  static const maxScan = 2000;

  final Node node;
  final NoteState state;
  Listings(this.node, this.state);

  bool _refreshing = false;
  String _key = '';
  List<Listing> _found = const [];

  /// Whether a listing may name [space]: a public forum or chat, and not the
  /// default forum every profile follows.
  static bool advertisable(String space) {
    if (space == 'general') return false;
    if (PublicChats.isChat(space)) return true;
    if (PublicNames.forum2Owner(space) != null) return space.length <= 200;
    return PublicNames.isForumSpace(space) && !space.contains(':');
  }

  static String typeOf(String space) =>
      PublicChats.isChat(space) ? 'chat' : 'forum';

  /// The register that switches every advert off at once.
  static const all = '*';

  /// Whether this person's devices advertise anything at all (the default).
  bool get enabled => state.value('noAdvert', all) != true;

  /// Whether this person's devices advertise [space]: by default they do,
  /// unless adverts are off altogether or for this space.
  bool advertises(String space) =>
      enabled && state.value('noAdvert', space) != true;

  /// Turns every advert on or off for all of this person's devices, and
  /// publishes the change.
  Future<void> setEnabled(bool on) async {
    await state.set('noAdvert', all, !on);
    await refresh();
  }

  /// Turns advertising [space] on or off for all of this person's devices,
  /// and publishes the change.
  Future<void> setAdvertised(String space, bool on) async {
    await state.set('noAdvert', space, !on);
    if (on && enabled) {
      await advertise(space);
    } else if (!on) {
      await withdraw(space);
    }
  }

  /// The name and description to advertise [space] under; null while an
  /// owner-bound space's own record has not arrived.
  ({String name, String description})? describe(
    String space, {
    String description = '',
  }) {
    if (PublicChats.isChat(space)) {
      final info = PublicChats.infoOf(node, space);
      if (info != null) {
        final named = PublicChats.slugOf(space) != null;
        // A named chat has no owner to describe it: the person who starts
        // it may.
        return named && info.description.isEmpty && description.isNotEmpty
            ? (name: info.name, description: description)
            : info;
      }
      return null;
    }
    final owner = PublicNames.forum2Owner(space);
    if (owner != null) {
      for (final o in node.store.objects(
        kind: 'forum',
        space: space,
        author: owner,
        limit: 20,
      )) {
        if (!o.isPublic || !node.visible(o)) continue;
        final p = o.data['payload'];
        if (p is! Json || p['name'] is! String) continue;
        return (
          name: p['name'] as String,
          description: p['description'] as String? ?? '',
        );
      }
      return null;
    }
    return (name: space, description: description);
  }

  /// Publishes a listing for [space], renewing any earlier one.
  Future<void> advertise(String space, {String description = ''}) async {
    if (!advertisable(space)) return;
    final info = describe(space, description: description);
    if (info == null) return;
    await _publish(space, {
      'type': typeOf(space),
      'name': PublicNames.cap(info.name, 100),
      'description': PublicNames.cap(info.description, 500),
    });
  }

  /// Takes this person's listing for [space] down.
  Future<void> withdraw(String space) => _publish(space, {'off': true});

  Future<void> _publish(String target, Json body) => node.publish(
    kind,
    {'space': target, ...body},
    space: home,
    expires: node.now() + lifetime.inMilliseconds,
  );

  /// The newest listing [author] wrote per space.
  Map<String, ({Json payload, int created})> _newestBy(String author) {
    final out = <String, ({Json payload, int created})>{};
    for (final o in node.store.objects(
      kind: kind,
      space: home,
      author: author,
      limit: 500,
    )) {
      if (!o.isPublic) continue;
      final p = o.data['payload'];
      if (p is! Json || p['space'] is! String) continue;
      out.putIfAbsent(p['space'] as String, () => (payload: p, created: o.created));
    }
    return out;
  }

  /// What [space] is for, as its newest advert says: this person's own, else
  /// the most recent from a friend. Empty when none says.
  String descriptionOf(String space) {
    final own = _newestBy(node.person)[space]?.payload['description'];
    if (own is String && own.isNotEmpty) return own;
    for (final l in found()) {
      if (l.space == space) return l.description;
    }
    return '';
  }

  /// Brings this person's listings in line with what they follow: lists
  /// spaces not yet listed, renews old listings, and takes down those for
  /// spaces left or turned off. Cheap when nothing changed.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final mine = _newestBy(node.person);
      final stale = node.now() - refreshAfter.inMilliseconds;
      for (final s in node.subscriptions.toList()) {
        if (!advertisable(s)) continue;
        final current = mine[s];
        final live = current != null && current.payload['off'] != true;
        if (!advertises(s)) {
          if (live) await withdraw(s);
          continue;
        }
        if (live && current.created > stale) continue;
        await advertise(
          s,
          description: current?.payload['description'] as String? ?? '',
        );
      }
      for (final entry in mine.entries) {
        if (entry.value.payload['off'] == true) continue;
        if (!node.subscriptions.contains(entry.key)) {
          await withdraw(entry.key);
        }
      }
    } finally {
      _refreshing = false;
    }
  }

  /// What friends follow, most followed first. Reads the (kind, space)
  /// index, bounded by [maxScan], and is kept until something changes.
  List<Listing> found() {
    // What the answer depends on: stored objects, and who counts as a friend.
    final key = '${node.changeSeq}/${node.contacts.length}/${node.blocked.length}';
    if (_key == key) return _found;
    final friends = {for (final c in node.contacts.values) c.person};
    final seen = <String>{};
    final bySpace = <String, Listing>{};
    final allowed = <String, bool>{};
    for (final o in node.store.objects(kind: kind, space: home, limit: maxScan)) {
      if (!o.isPublic ||
          !node.visible(o) ||
          o.author == node.person ||
          !friends.contains(o.author)) {
        continue;
      }
      final p = o.data['payload'];
      if (p is! Json) continue;
      final target = p['space'];
      if (target is! String || !(allowed[target] ??= advertisable(target))) {
        continue;
      }
      // Newest first: a person's latest word on a space is the one that counts.
      if (!seen.add('${o.author} $target') || p['off'] == true) continue;
      final name = p['name'];
      if (name is! String || name.trim().isEmpty) continue;
      final description = p['description'];
      final existing = bySpace[target];
      if (existing == null) {
        bySpace[target] = (
          space: target,
          type: typeOf(target),
          name: PublicNames.cap(name.trim(), 100),
          description: PublicNames.cap(
            description is String ? description.trim() : '',
            500,
          ),
          people: {o.author},
          newest: o.created,
        );
      } else {
        existing.people.add(o.author);
      }
    }
    _found = bySpace.values.toList()
      ..sort((a, b) {
        final byCount = b.people.length.compareTo(a.people.length);
        return byCount != 0
            ? byCount
            : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    _key = key;
    return _found;
  }

  /// Listings whose name or description contains [query].
  List<Listing> search(String query) {
    final q = query.trim().toLowerCase();
    return [
      for (final l in found())
        if (q.isEmpty ||
            l.name.toLowerCase().contains(q) ||
            l.description.toLowerCase().contains(q))
          l,
    ];
  }
}
