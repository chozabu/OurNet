import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart'
    show SecretBox, SecretBoxAuthenticationError, SecretKey;

import 'fast_crypto.dart';
import 'model.dart';
import 'node.dart';

/// Who a wall post is for.
enum WallAudience {
  /// The owner's friends: sealed with the wall key ([WallKeys]).
  friends,

  /// Anyone following the wall, and anyone it is reshared to.
  public,
}

/// A person's wall: their posts for their friends, with comments, in the
/// space `wall:<person>` (see docs/WALL.md and the Wall section of
/// docs/PROTOCOL.md).
///
/// Every wall object has an empty audience, so it travels like a public
/// forum post, to whoever follows the wall. A friends-only post or comment is
/// sealed with the wall's key for an epoch, which the owner hands to friends
/// in private `wall_key` records; followers without it carry what they
/// cannot open. A friend's wall is followed by default.
abstract final class Walls {
  static const postKind = 'wall_post';
  static const commentKind = 'wall_comment';
  static const hideKind = 'wall_hide';
  static const keyKind = 'wall_key';
  static const kinds = {postKind, commentKind, hideKind, keyKind};

  static const prefix = 'wall:';
  static const maxText = 20000;
  static const maxTitle = 200;

  static String space(String person) => '$prefix$person';

  /// The person whose wall [space] is; null for any other space.
  static String? ownerOf(String space) =>
      space.startsWith(prefix) && space.length > prefix.length
      ? space.substring(prefix.length)
      : null;

  /// Whether [o] may be kept at all: posts, hides and keys only from the
  /// wall's owner, comments from anyone, each in a wall and with the
  /// audience its kind has. Other kinds always may.
  static bool accepted(SignedObject o) {
    if (!kinds.contains(o.kind)) return true;
    final owner = ownerOf(o.space);
    if (owner == null) return false;
    return switch (o.kind) {
      keyKind => !o.isPublic && o.author == owner,
      commentKind => o.isPublic,
      _ => o.isPublic && o.author == owner,
    };
  }

  /// Whether a post or comment's [payload] is sealed with a wall key.
  static bool sealed(Json payload) => payload['box'] is String;

  /// What a sealed post or comment opens to, checked as its kind requires.
  static bool validPlain(String kind, Object? plain) =>
      plain is Map &&
      plain['text'] is String &&
      (plain['text'] as String).length <= maxText &&
      (kind == commentKind
          ? plain['parent'] == null || plain['parent'] is String
          : plain['title'] == null ||
                plain['title'] is String &&
                    (plain['title'] as String).length <= maxTitle);

  /// The original a reshare embeds, if it is one that may be: a public
  /// wall post (not itself a reshare) or forum post, verified as an object
  /// in its own right.
  static Future<SignedObject?> verifyShared(Object? share) async {
    if (share is! Map || share['object'] is! Map) return null;
    try {
      final o = SignedObject.fromJson(
        (share['object'] as Map).cast<String, dynamic>(),
      );
      if (!o.isPublic || !await o.valid()) return null;
      final p = o.data['payload'] as Json;
      if (o.kind == postKind) {
        if (!accepted(o) || sealed(p) || p['share'] != null) return null;
      } else if (o.kind != 'post') {
        return null;
      }
      return o;
    } catch (_) {
      return null;
    }
  }

  static List<int> _aad(String owner, int epoch, String kind, String? post) =>
      utf8.encode(
        'ournet/wall/1/$owner/$epoch/$kind${post == null ? '' : '/$post'}',
      );

  /// [plain] sealed under [key], bound to the wall, epoch, kind and, for a
  /// comment, the post it answers.
  static Future<String> seal(
    Json plain,
    List<int> key, {
    required String owner,
    required int epoch,
    required String kind,
    String? post,
  }) async {
    final box = await aead.encrypt(
      bytes(plain),
      secretKey: SecretKey(key),
      aad: _aad(owner, epoch, kind, post),
    );
    return b64(box.concatenation());
  }

  /// [box] opened with one of [keys]; null when none opens it.
  static Future<Json?> open(
    String box,
    Iterable<List<int>> keys, {
    required String owner,
    required int epoch,
    required String kind,
    String? post,
  }) async {
    final SecretBox sealed;
    try {
      sealed = SecretBox.fromConcatenation(
        unb64(box),
        nonceLength: 12,
        macLength: 16,
      );
    } catch (_) {
      return null;
    }
    for (final key in keys) {
      try {
        final plain = jsonDecode(
          utf8.decode(
            await aead.decrypt(
              sealed,
              secretKey: SecretKey(key),
              aad: _aad(owner, epoch, kind, post),
            ),
          ),
        );
        return validPlain(kind, plain) ? frozen(plain) as Json : null;
      } on SecretBoxAuthenticationError {
        continue;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Whether this device follows [person]'s wall.
  static bool following(Node node, String person) =>
      node.subscriptions.contains(space(person));
}

/// One key of a wall for one epoch, from one `wall_key` record.
class _Key {
  final String record;
  final List<int> key;
  final String encoded;

  /// The devices the record was wrapped for, and the people it was to.
  final Set<String> devices, people;
  _Key(this.record, this.key, this.encoded, this.devices, this.people);
}

/// Wall keys this device holds, and handing this person's own out.
///
/// Each epoch of a wall has one key (two, if two of the owner's devices
/// started an epoch at once: readers try each). The owner hands the current
/// one to friends when they next post to friends. A friend added since the
/// epoch's key was first handed out starts a new epoch, so they cannot open
/// what was posted before; removing or blocking a friend starts one too,
/// whose key goes to the remaining friends only.
/// The keys are kept in private records (`wall_key`), to friends in batches
/// within an object's audience limits, and to this person's own devices,
/// so they survive linking a new one.
///
/// Read from an insertion cursor over the kind, so a refresh costs what
/// arrived.
class WallKeys {
  final Node node;
  WallKeys(this.node);

  /// Keys by wall owner and epoch, oldest record first.
  final _keys = <String, Map<int, List<_Key>>>{};
  final _records = <String>{};
  int _cursor = 0;

  /// Records this device cannot open yet: another of its person's devices
  /// may grant their keys later.
  final _unread = <String>{};
  Future<void> _tail = Future.value();

  /// People one record carries a key to besides its author, and devices it
  /// is wrapped for: an object's limits ([SignedObject.valid]).
  static const _batchPeople = 63, _batchDevices = 128;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Takes in records that arrived. True when a new key was learned.
  Future<bool> refresh() => _serial(_refresh);

  Future<bool> _refresh() async {
    var added = false;
    for (final id in _unread.toList()) {
      _unread.remove(id);
      final o = node.store.get(id);
      // Still unreadable: [_take] notes it again.
      if (o != null && await _take(o)) added = true;
    }
    while (true) {
      final page = node.store.insertedOfKind(_cursor, Walls.keyKind);
      if (page.isEmpty) break;
      for (final (rowid, o) in page) {
        _cursor = rowid;
        if (await _take(o)) added = true;
      }
    }
    return added;
  }

  Future<bool> _take(SignedObject o) async {
    if (_records.contains(o.id) ||
        !Walls.accepted(o) ||
        !node.visible(o) ||
        !o.audience.contains(node.person)) {
      return false;
    }
    final p = await node.content(o);
    if (p == null) {
      if (_unread.length < 500) _unread.add(o.id);
      return false;
    }
    final epoch = p['epoch'], encoded = p['key'];
    if (epoch is! int || encoded is! String) return false;
    final List<int> key;
    try {
      key = unb64(encoded);
    } catch (_) {
      return false;
    }
    if (key.length != 32) return false;
    _records.add(o.id);
    final wraps = (o.data['payload'] as Json)['wraps'] as List;
    final list = (_keys[o.author] ??= {})[epoch] ??= [];
    list
      ..add(
        _Key(
          o.id,
          key,
          encoded,
          {
            for (final w in wraps)
              if (w is Map && w['device'] is String) w['device'] as String,
          },
          {...o.audience},
        ),
      )
      ..sort((a, b) => a.record.compareTo(b.record));
    return true;
  }

  /// The keys this device holds for [owner]'s wall in [epoch].
  Iterable<List<int>> keysFor(String owner, int epoch) =>
      _keys[owner]?[epoch]?.map((k) => k.key) ?? const [];

  /// Opens a sealed post or comment on [owner]'s wall; null when this
  /// device holds no key that opens it. Call [refresh] first.
  Future<Json?> open(SignedObject o, Json payload) async {
    final owner = Walls.ownerOf(o.space);
    final epoch = payload['epoch'], box = payload['box'];
    if (owner == null || epoch is! int || box is! String) return null;
    return Walls.open(
      box,
      keysFor(owner, epoch),
      owner: owner,
      epoch: epoch,
      kind: o.kind,
      post: o.kind == Walls.commentKind ? payload['post'] as String? : null,
    );
  }

  /// This person's newest epoch and the key new posts are sealed with: the
  /// oldest record's, so devices that started it at once agree. Null before
  /// the first friends-only post.
  ({int epoch, String key})? get current {
    final mine = _keys[node.person];
    if (mine == null || mine.isEmpty) return null;
    final epoch = mine.keys.reduce((a, b) => a > b ? a : b);
    return (epoch: epoch, key: mine[epoch]!.first.encoded);
  }

  /// Whether records of this person's wall keys exist that this device
  /// cannot open: it must wait for another of their devices to share them
  /// rather than start an epoch of its own.
  bool get waiting => _unread.any((id) {
    final o = node.store.get(id);
    return o != null && o.author == node.person;
  });

  /// The epoch and key to seal a friends-only post with, after making sure
  /// every friend and own device has it: starts epoch 0 on the first post.
  Future<({int epoch, List<int> key})> prepare() => _serial(() async {
    await _refresh();
    var now = current;
    if (now == null) {
      if (waiting) {
        throw StateError(
          'Your wall key has not reached this device yet. Open OurNet on '
          'another of your devices, then try again',
        );
      }
      await _publish(0, b64(randomBytes(32)), const []);
      await _refresh();
      now = current!;
    }
    // Someone who became a friend after this epoch's posts were written
    // must not read them: they start with a new one.
    final given = _given(now.epoch);
    if (given.isNotEmpty &&
        node.connections.mine().any((f) => !given.contains(f))) {
      await _publish(now.epoch + 1, b64(randomBytes(32)), const []);
      await _refresh();
      now = current!;
    }
    await _distribute(now.epoch, now.key);
    await _shareOwn();
    return (epoch: now.epoch, key: unb64(now.key));
  });

  /// Starts a new epoch, for after a friend was removed or blocked: what
  /// they were given stays readable to them, nothing new is. Its key goes
  /// to friends with the next friends-only post. Nothing happens before the
  /// first friends-only post.
  Future<void> rotate() => _serial(() async {
    await _refresh();
    final now = current;
    if (now == null) return;
    await _publish(now.epoch + 1, b64(randomBytes(32)), const []);
    await _refresh();
  });

  /// Hands every key of this person's wall to their own devices that lack
  /// it, such as one linked since: they then read what friends can and
  /// post in the current epoch.
  Future<int> shareOwn() => _serial(() async {
    await _refresh();
    return _shareOwn();
  });

  Future<int> _shareOwn() async {
    final own = _devicesOf(node.person);
    var shared = 0;
    for (final MapEntry(key: epoch, value: keys)
        in (_keys[node.person] ?? const <int, List<_Key>>{}).entries) {
      for (final key in {for (final k in keys) k.encoded}) {
        final covered = _covered(epoch, key);
        if (own.every(covered.contains)) continue;
        await _publish(epoch, key, const []);
        shared++;
      }
    }
    if (shared > 0) await _refresh();
    return shared;
  }

  /// The people besides this one that [epoch]'s key was handed to.
  Set<String> _given(int epoch) => {
    for (final k in _keys[node.person]?[epoch] ?? const <_Key>[])
      for (final p in k.people)
        if (p != node.person) p,
  };

  /// Devices the records of [key] in [epoch] were wrapped for.
  Set<String> _covered(int epoch, String key) => {
    for (final k in _keys[node.person]?[epoch] ?? const <_Key>[])
      if (k.encoded == key) ...k.devices,
  };

  /// [person]'s devices that a record to them is wrapped for.
  List<String> _devicesOf(String person) => [
    if (person == node.person) node.identity.device,
    for (final c in node.contacts.values)
      if (c.person == person &&
          c.device != node.identity.device &&
          !node.revoked.contains(c.device))
        c.device,
  ];

  /// Gives [key] to each friend with a device that has no record of it.
  Future<void> _distribute(int epoch, String key) async {
    final covered = _covered(epoch, key);
    final own = _devicesOf(node.person).length;
    final needy = [
      for (final friend in node.connections.mine())
        if (_devicesOf(friend).any((d) => !covered.contains(d))) friend,
    ]..sort();
    var batch = <String>[];
    var devices = own;
    for (final friend in needy) {
      final count = _devicesOf(friend).length;
      if (own + count > _batchDevices) continue;
      if (batch.length >= _batchPeople || devices + count > _batchDevices) {
        await _publish(epoch, key, batch);
        batch = [];
        devices = own;
      }
      batch.add(friend);
      devices += count;
    }
    if (batch.isNotEmpty) await _publish(epoch, key, batch);
  }

  Future<SignedObject> _publish(int epoch, String key, List<String> people) =>
      node.publish(
        Walls.keyKind,
        {'epoch': epoch, 'key': key},
        space: Walls.space(node.person),
        // Always to this person's own devices too: see [Node.publish].
        audience: [node.person, ...people],
      );
}

/// A comment on a wall post.
class WallComment {
  final SignedObject object;
  final String post;
  final String text;
  final String? parent;

  /// The epoch of the post it answers, for a sealed comment.
  final int? epoch;

  /// How deep it sits under the post, set when threaded (0 for an answer
  /// to the post itself).
  int depth = 0;
  WallComment(this.object, this.post, this.text, this.parent, this.epoch);
  String get id => object.id;
  String get author => object.author;
  int get created => object.created;
}

/// A post on someone's wall.
class WallPost {
  final SignedObject object;
  final String text;
  final String? title;
  final WallAudience audience;

  /// The epoch whose key sealed it; null for a public post.
  final int? epoch;

  /// What it reshares, verified: a public wall post or forum post.
  final SignedObject? shared;

  /// Its comments, threaded: depth first, oldest first at each level.
  List<WallComment> comments = const [];
  WallPost(
    this.object,
    this.text,
    this.title,
    this.audience,
    this.epoch,
    this.shared,
  );
  String get id => object.id;

  /// Whose wall it is on; only they post there.
  String get owner => object.author;
  int get created => object.created;
  bool get isPublic => audience == WallAudience.public;

  /// The reshared original's content.
  Json? get sharedPayload => shared?.data['payload'] as Json?;
}

/// Posts on one or more walls, newest first, with their comments.
///
/// Read back in pages from newest ([more]), then kept current from an
/// insertion cursor ([refresh]), so a refresh costs what arrived rather than
/// what exists. Comments and hides are read back as far as the posts are.
abstract class WallView {
  final Node node;
  WallView(this.node) : _cursor = node.store.insertionCursor;

  /// The one wall shown, or null for several.
  String? get _space;

  /// Whether posts in [space] are shown.
  bool _includes(String space);

  /// What decides which posts are shown besides the posts: a change reads
  /// everything again.
  String _policy() => '${node.blocked.toList()..sort()}';

  static const pageSize = 30;

  /// Posts looked at per call to [more] at most.
  static const maxScanned = 512;

  final _posts = <String, WallPost>{};
  final _comments = <String, Map<String, WallComment>>{};
  final _hidden = <String>{};

  /// Sealed posts and comments this device holds no key for yet.
  final _sealed = <String, SignedObject>{};
  final _seen = <String>{};
  (int, String)? _postsAfter, _notesAfter;
  bool _exhausted = false, _loaded = false;
  int _cursor;
  String _applied = '';
  List<WallPost>? _sorted;
  Future<void> _tail = Future.value();

  /// Changes whenever [posts] may have.
  int version = 0;

  bool get loaded => _loaded;

  /// Whether every post has been read back.
  bool get exhausted => _exhausted;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Newest first, without hidden posts; each with its comments threaded.
  List<WallPost> get posts => _sorted ??= () {
    final shown = [
      for (final p in _posts.values)
        if (!_hidden.contains(p.id) && !node.blocked.contains(p.owner)) p,
    ]..sort(_newest);
    for (final p in shown) {
      p.comments = _thread(p);
    }
    return shown;
  }();

  static int _newest(WallPost a, WallPost b) {
    final order = b.created.compareTo(a.created);
    return order != 0 ? order : a.id.compareTo(b.id);
  }

  List<WallComment> _thread(WallPost post) {
    final all =
        [
          for (final c in (_comments[post.id] ?? const {}).values)
            if (!_hidden.contains(c.id) &&
                !node.blocked.contains(c.author) &&
                c.epoch == post.epoch)
              c,
        ]..sort((a, b) {
          final order = a.created.compareTo(b.created);
          return order != 0 ? order : a.id.compareTo(b.id);
        });
    final ids = {for (final c in all) c.id};
    final children = <String?, List<WallComment>>{};
    for (final c in all) {
      final parent = ids.contains(c.parent) && c.parent != c.id
          ? c.parent
          : null;
      (children[parent] ??= []).add(c);
    }
    final ordered = <WallComment>[];
    final visited = <String>{};
    void walk(String? parent, int depth) {
      for (final c in children[parent] ?? const <WallComment>[]) {
        if (!visited.add(c.id)) continue;
        c.depth = depth;
        ordered.add(c);
        walk(c.id, depth < 8 ? depth + 1 : depth);
      }
    }

    walk(null, 0);
    return ordered;
  }

  /// Whether the wall's owner hid (or deleted) [id].
  bool hidden(String id) => _hidden.contains(id);

  /// The post this view holds as [id], with its comments.
  WallPost? post(String id) {
    posts;
    return _posts[id];
  }

  /// Reads the first page, or takes in what arrived since. True when
  /// [posts] changed.
  Future<bool> refresh() => _serial(() async {
    final before = version;
    final policy = _policy();
    if (_loaded && policy != _applied) _reset();
    _applied = policy;
    if (!_loaded) {
      _cursor = node.store.insertionCursor;
      await node.wallKeys.refresh();
      await _readBack(pageSize);
      _loaded = true;
      _changed();
    } else {
      await _catchUp();
    }
    return version != before;
  });

  /// Reads further back, about a page more. True if any were added.
  Future<bool> more() => _serial(() async {
    final before = version;
    await _readBack(pageSize);
    return version != before;
  });

  void _reset() {
    _posts.clear();
    _comments.clear();
    _hidden.clear();
    _sealed.clear();
    _seen.clear();
    _postsAfter = null;
    _notesAfter = null;
    _exhausted = false;
    _loaded = false;
    _changed();
  }

  void _changed() {
    _sorted = null;
    version++;
  }

  Future<void> _readBack(int count) async {
    final want = _posts.length + count;
    final slice = TimeSlice();
    var changed = false;
    var scanned = 0;
    read:
    while (!_exhausted && _posts.length < want && scanned < maxScanned) {
      final page = node.store.objects(
        kind: Walls.postKind,
        space: _space,
        after: _postsAfter,
        limit: 64,
      );
      if (page.isEmpty) {
        _exhausted = true;
        break;
      }
      for (final o in page) {
        if (_posts.length >= want) break read;
        _postsAfter = (o.created, o.id);
        scanned++;
        await slice.pause();
        if (await _take(o)) changed = true;
      }
    }
    // Comments and hides come after what they are about, so they are read
    // back as far as the posts have been.
    final floor = _exhausted ? null : _postsAfter?.$1;
    walk:
    while (true) {
      final page = node.store.objects(
        kinds: const [Walls.commentKind, Walls.hideKind],
        space: _space,
        after: _notesAfter,
        limit: 128,
      );
      if (page.isEmpty) break;
      for (final o in page) {
        if (floor != null && o.created < floor) break walk;
        _notesAfter = (o.created, o.id);
        await slice.pause();
        if (await _take(o)) changed = true;
      }
    }
    if (changed) _changed();
  }

  Future<void> _catchUp() async {
    final target = node.store.insertionCursor;
    var changed = false;
    final slice = TimeSlice();
    if (await node.wallKeys.refresh() && _sealed.isNotEmpty) {
      for (final o in _sealed.values.toList()) {
        await slice.pause();
        if (await _take(o)) changed = true;
      }
    }
    if (target != _cursor) {
      var cursor = _cursor;
      while (true) {
        final page = node.store.insertedAfter(cursor, const [
          Walls.postKind,
          Walls.commentKind,
          Walls.hideKind,
        ]);
        if (page.isEmpty) break;
        for (final (sequence, o) in page) {
          cursor = sequence;
          await slice.pause();
          if (await _take(o)) changed = true;
        }
      }
      _cursor = cursor > target ? cursor : target;
    }
    if (changed) _changed();
  }

  /// Takes in one post, comment or hide; true when it is shown or changes
  /// what is. Each is taken once.
  Future<bool> _take(SignedObject o) async {
    if (!_includes(o.space) ||
        !Walls.accepted(o) ||
        !node.visible(o) ||
        // Taken already, unless it is sealed and a key may have come since.
        !_seen.add(o.id) && !_sealed.containsKey(o.id)) {
      return false;
    }
    final p = o.data['payload'];
    if (p is! Json || !node.registry.accepts(o.kind, p)) return false;
    switch (o.kind) {
      case Walls.hideKind:
        _hidden.add(p['object'] as String);
        return true;
      case Walls.postKind:
        final post = await _read(o, p);
        if (post == null) return false;
        _posts[o.id] = post;
        return true;
      case Walls.commentKind:
        final String text;
        String? parent;
        if (Walls.sealed(p)) {
          final plain = await node.wallKeys.open(o, p);
          if (plain == null) {
            _sealed[o.id] = o;
            return false;
          }
          _sealed.remove(o.id);
          text = plain['text'] as String;
          parent = plain['parent'] as String?;
        } else {
          text = p['text'] as String;
          parent = p['parent'] as String?;
        }
        final comment = WallComment(
          o,
          p['post'] as String,
          text,
          parent,
          p['epoch'] as int?,
        );
        (_comments[comment.post] ??= {})[o.id] = comment;
        return _posts.containsKey(comment.post);
    }
    return false;
  }

  Future<WallPost?> _read(SignedObject o, Json p) async {
    if (Walls.sealed(p)) {
      final plain = await node.wallKeys.open(o, p);
      if (plain == null) {
        _sealed[o.id] = o;
        return null;
      }
      _sealed.remove(o.id);
      return WallPost(
        o,
        plain['text'] as String,
        plain['title'] as String?,
        WallAudience.friends,
        p['epoch'] as int,
        null,
      );
    }
    SignedObject? shared;
    if (p['share'] != null) {
      shared = await Walls.verifyShared(p['share']);
      // A reshare whose original does not verify is not shown at all.
      if (shared == null) return null;
    }
    return WallPost(
      o,
      p['text'] as String,
      p['title'] as String?,
      WallAudience.public,
      null,
      shared,
    );
  }

  /// Posts and comments by others not yet looked at, up to [cap].
  int unseen({int cap = 100}) {
    var n = 0;
    for (final p in posts) {
      for (final o in [p.object, for (final c in p.comments) c.object]) {
        if (o.author == node.person ||
            node.store.setting('seen/${o.id}') == true) {
          continue;
        }
        if (++n >= cap) return n;
      }
    }
    return n;
  }

  /// Marks every post and comment shown as looked at.
  void markSeen() {
    final ids = [
      for (final p in posts)
        for (final o in [p.object, for (final c in p.comments) c.object])
          if (o.author != node.person &&
              node.store.setting('seen/${o.id}') != true)
            o.id,
    ];
    if (ids.isEmpty) return;
    node.store.batch(() {
      for (final id in ids) {
        node.store.set('seen/$id', true);
      }
    });
  }

  /// Posts [text] on this person's own wall. A friends-only post is sealed
  /// with the wall key, which friends who lack it are given first.
  Future<SignedObject> publish(
    String text, {
    String? title,
    WallAudience audience = WallAudience.friends,
  }) async {
    text = text.trim();
    final t = title?.trim();
    if (text.isEmpty) throw StateError('Write something first');
    if (text.length > Walls.maxText) throw StateError('That post is too long');
    final plain = <String, dynamic>{
      'text': text,
      if (t != null && t.isNotEmpty) 'title': t,
    };
    if (!Walls.validPlain(Walls.postKind, plain)) {
      throw StateError('That title is too long');
    }
    final space = Walls.space(node.person);
    if (audience == WallAudience.public) {
      return node.publish(Walls.postKind, plain, space: space);
    }
    final key = await node.wallKeys.prepare();
    return node.publish(Walls.postKind, {
      'epoch': key.epoch,
      'box': await Walls.seal(
        plain,
        key.key,
        owner: node.person,
        epoch: key.epoch,
        kind: Walls.postKind,
      ),
    }, space: space);
  }

  /// Comments on [post]; [parent] is the comment answered. A comment on a
  /// friends-only post is sealed with the post's key, so all its readers
  /// read it.
  Future<SignedObject> comment(
    WallPost post,
    String text, {
    String? parent,
  }) async {
    text = text.trim();
    if (text.isEmpty) throw StateError('Write something first');
    if (text.length > Walls.maxText) {
      throw StateError('That comment is too long');
    }
    final plain = <String, dynamic>{'text': text, 'parent': ?parent};
    final space = post.object.space;
    final epoch = post.epoch;
    if (epoch == null) {
      return node.publish(Walls.commentKind, {
        'post': post.id,
        ...plain,
      }, space: space);
    }
    return node.publish(Walls.commentKind, {
      'post': post.id,
      'epoch': epoch,
      'box': await Walls.seal(
        plain,
        node.wallKeys.keysFor(post.owner, epoch).first,
        owner: post.owner,
        epoch: epoch,
        kind: Walls.commentKind,
        post: post.id,
      ),
    }, space: space);
  }

  /// Hides [object], a comment or post on this person's own wall, for
  /// everyone: deleting one's own post is hiding it.
  Future<SignedObject> hide(SignedObject object) {
    if (object.space != Walls.space(node.person)) {
      return Future.error(StateError('Only on your own wall'));
    }
    return node.publish(Walls.hideKind, {
      'object': object.id,
    }, space: object.space);
  }

  /// Reshares [original], a public wall post or forum post, on this
  /// person's own wall with [text] above it. A reshare of a reshare embeds
  /// the original, not the chain.
  Future<SignedObject> reshare(
    SignedObject original, [
    String text = '',
  ]) async {
    var source = original;
    final p = source.data['payload'];
    if (source.kind == Walls.postKind && p is Map && p['share'] != null) {
      source =
          await Walls.verifyShared(p['share']) ??
          (throw StateError('That post cannot be shared'));
    }
    if (await Walls.verifyShared({'object': source.toJson()}) == null) {
      throw StateError('Only public posts can be shared');
    }
    return node.publish(Walls.postKind, {
      'text': text.trim(),
      'share': {'object': source.toJson()},
    }, space: Walls.space(node.person));
  }
}

/// One person's wall: what they posted that this device can read.
class Wall extends WallView {
  final String person;
  Wall(super.node, this.person);

  @override
  String get _space => Walls.space(person);

  @override
  bool _includes(String space) => space == _space;

  bool get mine => person == node.person;

  /// Whether this device follows the wall.
  bool get following => Walls.following(node, person);

  /// Follows or stops following the wall: see [Node.followWall].
  void follow(bool enabled) => node.followWall(person, enabled);
}

/// Every followed wall merged: this person's own and their friends' by
/// default, and public walls they follow.
class WallFeed extends WallView {
  WallFeed(super.node);

  @override
  String? get _space => null;

  @override
  bool _includes(String space) =>
      Walls.ownerOf(space) != null && node.subscriptions.contains(space);

  @override
  String _policy() =>
      '${super._policy()}|${[for (final s in node.subscriptions)
        if (s.startsWith(Walls.prefix)) s]..sort()}';
}
