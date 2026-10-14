import 'dart:math' as math;

import 'model.dart';
import 'node.dart';

/// Up and down votes on forum posts, as on Reddit.
///
/// A vote is a `vote` object (`object`, `value` of 1, -1 or 0 to withdraw)
/// in the post's space: public for a public forum's `post`, sealed to the
/// group like the post itself for a group forum's `room_post`. Each person's
/// latest vote on a post counts. Builds that predate forum votes store and
/// replicate them without showing them.
///
/// Like [MessageUpdates], this keeps a small index in settings consumed in
/// arrival order from a cursor, so tallying costs what arrived rather than
/// the length of history. A group post is voted on by [ForumVotes.target],
/// so copies shared with later members carry the same score.
class ForumVotes {
  final Node node;
  ForumVotes(this.node);

  static const kind = 'vote';
  static const _cursorKey = 'forumVotes/cursor';
  static const _waitingKey = 'forumVotes/waiting';
  static const _maxWaiting = 500;

  Future<void>? _running;
  bool _again = false;

  /// What a vote on the post [object] with [payload] points at: the post it
  /// was first published as, which a shared group copy remembers.
  static String target(SignedObject object, Json payload) =>
      object.kind == 'room_post'
      ? payload['copyOf'] as String? ?? object.id
      : object.id;

  /// Indexes every vote stored since the last call. Concurrent calls share
  /// one pass, which repeats once if more arrived meanwhile.
  Future<void> catchUp() {
    _again = true;
    return _running ??= () async {
      try {
        while (_again) {
          _again = false;
          await _consume();
        }
      } finally {
        _running = null;
      }
    }();
  }

  Future<void> _consume() async {
    var cursor = node.store.setting(_cursorKey) as int? ?? 0;
    final waiting = <String>[
      ...?(node.store.setting(_waitingKey) as List?)?.cast<String>(),
    ];
    final before = waiting.length;
    // Votes this device could not read when they arrived; a group key that
    // arrived later may open them.
    for (final id in waiting.toList()) {
      final o = node.store.get(id);
      final p = o == null ? null : await node.content(o);
      if (o == null || p != null) waiting.remove(id);
      if (o != null && p != null) _apply(o, p);
    }
    var changed = waiting.length != before;
    while (true) {
      final page = node.store.objectsAfter(kind, cursor);
      if (page.isEmpty) break;
      for (final (rowid, o) in page) {
        cursor = rowid;
        final p = await node.content(o);
        if (p != null) {
          _apply(o, p);
        } else if (node.visible(o) &&
            waiting.length < _maxWaiting &&
            !waiting.contains(o.id)) {
          waiting.add(o.id);
          changed = true;
        }
      }
      node.store.set(_cursorKey, cursor);
      if (page.length < 128) break;
    }
    if (changed) node.store.set(_waitingKey, waiting);
  }

  void _apply(SignedObject o, Json p) {
    final target = p['object'];
    final value = p['value'];
    if (target is! String || value is! int || value.abs() > 1) return;
    final key = 'votes/$target';
    final all = Map<String, dynamic>.from(
      node.store.setting(key) as Map? ?? const {},
    );
    final previous = all[o.author];
    if (previous is Map) {
      final order = (previous['created'] as int).compareTo(o.created);
      if (order > 0 || order == 0 && '${previous['id']}'.compareTo(o.id) >= 0) {
        return;
      }
    }
    all[o.author] = {
      'value': value,
      'created': o.created,
      'id': o.id,
      'space': o.space,
      'public': o.isPublic,
    };
    node.store.set(key, all);
  }

  /// Each person's current vote on [target], left out where withdrawn. Only
  /// votes in [space] count, public ones for a public post and sealed ones
  /// for a group's; [voters], when given, limits who counts (a group's
  /// members). Blocked people never count.
  Map<String, int> votes(
    String target, {
    required String space,
    required bool public,
    Set<String>? voters,
  }) {
    final all = node.store.setting('votes/$target');
    if (all is! Map) return const {};
    return {
      for (final MapEntry(:key, :value) in all.entries)
        if (value is Map &&
            value['value'] is int &&
            value['value'] != 0 &&
            value['space'] == space &&
            value['public'] == public &&
            (voters == null || voters.contains(key)) &&
            !node.blocked.contains(key))
          key as String: value['value'] as int,
    };
  }

  /// The score of [post]: ups minus downs.
  int score(SignedObject post, Json payload, {Set<String>? voters}) =>
      tally(post, payload, voters: voters).score;

  /// Ups, downs and this person's own vote on [post].
  VoteTally tally(SignedObject post, Json payload, {Set<String>? voters}) {
    final all = votes(
      target(post, payload),
      space: post.space,
      public: post.isPublic,
      voters: voters,
    );
    var up = 0, down = 0;
    for (final v in all.values) {
      if (v > 0) up++;
      if (v < 0) down++;
    }
    return VoteTally(up, down, all[node.person] ?? 0);
  }

  /// Votes [value] (1, -1, or 0 to withdraw) on [post]. A group post's vote
  /// goes to [audience], the group's members, as its posts do.
  Future<SignedObject> vote(
    SignedObject post,
    Json payload,
    int value, {
    List<String> audience = const [],
  }) async {
    if (value.abs() > 1) throw ArgumentError.value(value, 'value');
    if (!post.isPublic && audience.isEmpty) {
      throw StateError('A private post is voted on by its group');
    }
    final o = await node.publish(
      kind,
      {'object': target(post, payload), 'value': value},
      space: post.space,
      audience: post.isPublic ? const [] : audience,
    );
    _apply(o, {'object': target(post, payload), 'value': value});
    return o;
  }
}

/// How a post has been voted on.
class VoteTally {
  final int up, down;

  /// This person's vote: 1, -1 or 0.
  final int mine;
  const VoteTally(this.up, this.down, this.mine);

  int get score => up - down;

  /// Reddit's "hot" rank: the score's order of magnitude plus the time the
  /// post was written, where 12.5 hours count as much as ten times the score.
  static double hot(int score, int written) {
    final order = math.log(math.max(score.abs(), 1)) / math.ln10;
    final sign = score.sign;
    return sign * order + (written / 1000 - 1134028003) / 45000;
  }
}
