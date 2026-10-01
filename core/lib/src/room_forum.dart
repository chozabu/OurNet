import 'dart:async';
import 'everyday.dart';
import 'model.dart';
import 'node.dart';

/// One discussion post in a private group's forum.
class ForumPost {
  final SignedObject object;
  final Json data;
  ForumPost(this.object, this.data);

  /// History shared with a new member is republished by the group's owner, so
  /// the person who wrote it is named in the payload.
  String get author => data['history'] == true
      ? data['originalAuthor'] as String? ?? object.author
      : object.author;

  /// When it was first written; a shared copy keeps the original's time.
  int get sent => data['sent'] as int? ?? object.created;

  /// What other posts' `parent` refers to: the first object it was published
  /// as, which a shared copy remembers.
  String get root => data['copyOf'] as String? ?? object.id;
}

/// A private group's forum: threaded discussions only its members can read.
///
/// The same shape as a public forum (a post with a title starts a discussion,
/// replies point at their parent), but encrypted to the group and keyed by the
/// group's room ID. Posts never change, so there is no epoch machinery:
/// whoever is a member now can read what members wrote, and history shared
/// with a person who joins later arrives as copies that remember what they
/// copy ([ForumPost.root]), so threads still hang together.
///
/// Read once when a group's forum is opened and then kept current from an
/// insertion cursor, so a refresh costs what arrived rather than what exists.
class RoomForum {
  final Node node;
  final String space;
  EverydayItem _room;
  final _posts = <String, ForumPost>{};
  int _cursor;
  bool _loaded = false;
  String _blocked;
  Future<void>? _loading;
  _Tree? _tree;

  RoomForum(this.node, EverydayItem room)
    : space = room.object.space,
      _room = room,
      _cursor = node.store.insertionCursor,
      _blocked = '${node.blocked.toList()..sort()}';

  bool get loaded => _loaded;
  EverydayItem get room => _room;

  /// Who a new post goes to: the group's members now. Also learns their
  /// devices from the room record, as writing to the group's chat does.
  Future<List<String>> audience() async {
    final everyday = Everyday(node);
    _room = await everyday.current(_room);
    await everyday.prepare(_room);
    return everyday.members(_room);
  }

  /// Publishes a post (`text`, and `title` or `parent`) to the group.
  Future<SignedObject> publish(Json content) async => node.publish(
    'room_post',
    content,
    space: space,
    audience: await audience(),
  );

  /// Every post a member may read, as published (shared copies included).
  Iterable<ForumPost> get all => _posts.values;

  /// Reads the group's posts, in time-sliced pages. Safe to call again.
  Future<void> load() => _loading ??= _load().whenComplete(() {
    _loading = null;
  });

  Future<void> _load() async {
    final everyday = Everyday(node);
    _room = await everyday.current(_room);
    _blocked = '${node.blocked.toList()..sort()}';
    _posts.clear();
    _tree = null;
    final start = node.store.insertionCursor;
    final slice = TimeSlice();
    (int, String)? after;
    while (true) {
      final page = node.store.objects(
        kind: 'room_post',
        space: space,
        after: after,
        limit: 128,
      );
      if (page.isEmpty) break;
      after = (page.last.created, page.last.id);
      for (final o in page) {
        await slice.pause();
        await _take(o);
      }
    }
    _cursor = start;
    _loaded = true;
    // Anything that arrived while reading is caught by the next refresh.
  }

  /// Takes in what arrived since the last call. True when anything changed,
  /// including a membership change, which reads the forum again.
  Future<bool> refresh() async {
    if (!_loaded) return false;
    final target = node.store.insertionCursor;
    final everyday = Everyday(node);
    final next = await everyday.current(_room);
    final blocked = '${node.blocked.toList()..sort()}';
    if (everyday.epoch(next) != everyday.epoch(_room) ||
        next.data['generation'] != _room.data['generation'] ||
        blocked != _blocked) {
      _room = next;
      await load();
      return true;
    }
    _room = next;
    if (target == _cursor) return false;
    var changed = false;
    var cursor = _cursor;
    final slice = TimeSlice();
    while (true) {
      final page = node.store.insertedAfter(cursor, ['room_post']);
      if (page.isEmpty) break;
      for (final (sequence, o) in page) {
        cursor = sequence;
        if (o.space != space) continue;
        await slice.pause();
        if (await _take(o)) changed = true;
      }
    }
    _cursor = cursor > target ? cursor : target;
    return changed;
  }

  Future<bool> _take(SignedObject o) async {
    if (o.isPublic || !node.visible(o) || _posts.containsKey(o.id)) {
      return false;
    }
    final p = await node.content(o);
    if (p == null) return false;
    final post = ForumPost(o, p);
    final members = (_room.data['members'] as List).cast<String>();
    final accepted = p['history'] == true
        // Shared history counts only from the owner, naming a member.
        ? o.author == _room.data['owner'] &&
              p['originalAuthor'] is String &&
              members.contains(p['originalAuthor'])
        : members.contains(o.author);
    if (!accepted || node.blocked.contains(post.author)) return false;
    _posts[o.id] = post;
    _tree = null;
    return true;
  }

  _Tree get _t => _tree ??= _Tree(_posts.values.toList());

  /// Discussions (posts that answer nothing), newest first.
  List<ForumPost> get topics => _t.topics;

  /// A discussion and its replies, depth first and oldest first within each
  /// level; the root comes first.
  List<ForumPost> thread(String rootId) => _t.thread(rootId);

  /// Direct replies to a post.
  int replies(String id) => _t.children[id]?.length ?? 0;

  /// How deep a post sits in its discussion (0 for the first post).
  int depth(String id) => _t.depth(id);

  /// The post that a reply answers, resolved to the post shown for it.
  String? parentOf(String id) => _t.parent[id];

  /// The posts as shown: shared copies of posts this device also has dropped.
  Iterable<ForumPost> get shown => _t.byId.values;

  /// The group's posts as they were published, for sharing with new members.
  static Future<List<ForumPost>> read(Node node, EverydayItem room) async {
    final forum = RoomForum(node, room);
    await forum.load();
    return forum.shown.toList();
  }
}

class _Tree {
  final byId = <String, ForumPost>{};
  final parent = <String, String?>{};
  final children = <String, List<ForumPost>>{};
  final topics = <ForumPost>[];

  _Tree(List<ForumPost> posts) {
    final originals = {for (final p in posts) p.object.id};
    // A copy is dropped where this device also holds what it copies; where it
    // does not, the copy answers to the original's ID.
    final alias = <String, String>{};
    for (final p in posts) {
      if (p.root != p.object.id && originals.contains(p.root)) continue;
      byId[p.object.id] = p;
      if (p.root != p.object.id) alias[p.root] = p.object.id;
    }
    for (final p in byId.values) {
      final raw = p.data['parent'] as String?;
      final resolved = raw == null ? null : alias[raw] ?? raw;
      parent[p.object.id] = resolved != null && byId.containsKey(resolved)
          ? resolved
          : null;
    }
    for (final p in byId.values) {
      final up = parent[p.object.id];
      if (up == null) {
        topics.add(p);
      } else {
        (children[up] ??= []).add(p);
      }
    }
    topics.sort(_newest);
    for (final list in children.values) {
      list.sort((a, b) => _oldest(a, b));
    }
  }

  static int _newest(ForumPost a, ForumPost b) {
    final order = b.sent.compareTo(a.sent);
    return order != 0 ? order : b.object.id.compareTo(a.object.id);
  }

  static int _oldest(ForumPost a, ForumPost b) {
    final order = a.sent.compareTo(b.sent);
    return order != 0 ? order : a.object.id.compareTo(b.object.id);
  }

  List<ForumPost> thread(String rootId) {
    final ordered = <ForumPost>[];
    final visited = <String>{};
    final pending = [rootId];
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!visited.add(id)) continue;
      final found = byId[id];
      if (found != null) ordered.add(found);
      pending.addAll(
        (children[id] ?? const []).reversed.map((r) => r.object.id),
      );
    }
    return ordered;
  }

  int depth(String id) {
    var depth = 0;
    final seen = <String>{id};
    var up = parent[id];
    while (up != null && seen.add(up) && depth < 8) {
      depth++;
      up = parent[up];
    }
    return depth;
  }
}
