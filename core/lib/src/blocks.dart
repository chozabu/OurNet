import 'dart:collection';

import 'model.dart';
import 'node.dart';
import 'public_names.dart';

/// The people blocked everywhere ([Node.blocked]): a set that counts its
/// changes, so [BlockPolicy.version] notices callers that edit it directly.
class PolicySet extends SetBase<String> {
  final _items = <String>{};

  /// Rises on every addition or removal.
  int changes = 0;

  @override
  bool add(String value) {
    final added = _items.add(value);
    if (added) changes++;
    return added;
  }

  @override
  bool remove(Object? value) {
    final removed = _items.remove(value);
    if (removed) changes++;
    return removed;
  }

  @override
  bool contains(Object? element) => _items.contains(element);

  @override
  String? lookup(Object? element) => _items.lookup(element);

  @override
  Iterator<String> get iterator => _items.iterator;

  @override
  int get length => _items.length;

  @override
  Set<String> toSet() => {..._items};
}

/// What this person chose about someone in some spaces (or everywhere, `*`).
enum ScopeState {
  /// Hidden there and not passed on there; still connected, DMs still fine.
  /// In a private group only hidden, so other members still get its items.
  block,

  /// Hidden only: still passed on, still connected.
  mute,

  /// Never hidden by a subscribed list ([BlockPolicy.everywhere] only).
  allow,

  /// None of these.
  none,
}

/// What a subscribed list does to the people on it.
enum ListMode {
  /// Hidden only, with a note saying which list hid them.
  hide,

  /// Hidden and not passed on, like a personal per-space block.
  block,
}

/// One entry on a public block list.
class BlockEntry {
  final String owner, list, person;

  /// Where it applies: null for everywhere, else these spaces.
  final List<String>? spaces;
  final String? reason;
  final List<String> evidence;
  final int created;
  const BlockEntry(
    this.owner,
    this.list,
    this.person, {
    this.spaces,
    this.reason,
    this.evidence = const [],
    this.created = 0,
  });

  bool covers(String space) => spaces == null || spaces!.contains(space);
}

/// A public block list: its name, and who keeps it.
class BlockList {
  final String owner, list, name, description;
  const BlockList(this.owner, this.list, this.name, this.description);
  String get space => BlockPolicy.space(owner, list);
}

/// An entry of a subscribed list that applies here, with what it does.
class BlockHit {
  final BlockEntry entry;
  final ListMode mode;
  const BlockHit(this.entry, this.mode);
}

/// Who this person keeps out, where, and how: see docs/PROTOCOL.md
/// ("Blocking").
///
/// - A block everywhere is the `contact_state` block, [Node.blocked]: nothing
///   of theirs is shown or exchanged.
/// - A block in some spaces (a forum, a chat, a group, a wall) hides their
///   objects there and stops passing them on there. In a private group it
///   only hides, so the other members still get what they wrote.
/// - A mute, everywhere or in some spaces, only hides.
/// - Public block lists (`blocks:<owner>/<list>`) can be subscribed to,
///   hiding (default) or blocking the people on them. A list never hides an
///   admitted friend, or anyone this person allowed: those show as a note.
///
/// Choices are `block_scope` and `block_sub` records sealed to this person,
/// newest wins, so every one of their devices agrees, as with
/// `contact_state`. Builds before them ignore all four kinds.
class BlockPolicy {
  final Node node;
  BlockPolicy(this.node) {
    _load();
  }

  static const scopeKind = 'block_scope';
  static const subKind = 'block_sub';
  static const listKind = 'block_list';
  static const entryKind = 'block_entry';
  static const kinds = {scopeKind, subKind, listKind, entryKind};

  /// Kinds kept among this person's own devices.
  static const privateKinds = {scopeKind, subKind};

  static const everywhere = '*';
  static const prefix = 'blocks:';
  static const maxSpaces = 32;
  static const maxEvidence = 16;
  static const maxReason = 500;

  /// Entries read from one list at most.
  static const maxEntries = 10000;

  /// The space holding [owner]'s list [list].
  static String space(String owner, String list) => '$prefix$owner/$list';

  /// The owner and list a list space names; null for any other space.
  static (String, String)? parseSpace(String space) {
    if (!space.startsWith(prefix)) return null;
    final rest = space.substring(prefix.length);
    final slash = rest.indexOf('/');
    if (slash <= 0 || slash == rest.length - 1) return null;
    final owner = rest.substring(0, slash), list = rest.substring(slash + 1);
    if (owner.length > 64 || PublicNames.slug(list) != list) return null;
    return (owner, list);
  }

  /// Whether [o] may be in its space: only a list's owner writes to it.
  static bool accepted(SignedObject o) {
    if (!o.space.startsWith(prefix)) return true;
    final parsed = parseSpace(o.space);
    return parsed != null && parsed.$1 == o.author;
  }

  static String link(String owner, String list) =>
      'ournet://blocks/${Uri.encodeComponent(owner)}/${Uri.encodeComponent(list)}';

  /// The owner and list an `ournet://blocks/â€¦` link names.
  static (String, String)? parseLink(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.scheme != 'ournet' || uri.host != 'blocks') {
      return null;
    }
    final parts = uri.pathSegments;
    if (parts.length != 2) return null;
    return parseSpace(space(parts[0], parts[1]));
  }

  int _version = 0;

  /// Changes whenever anything here may hide or show something: a cheap
  /// cache key for views that live in memory.
  int get version => _version + node.blocked.changes;

  /// person -> space -> (state, when chosen); `none` remembered so an older
  /// choice arriving later does not win.
  final _scoped = <String, Map<String, (ScopeState, int)>>{};

  /// `owner/list` -> (mode, when chosen, removed).
  final _subs = <String, (ListMode, int, bool)>{};

  /// Entries of subscribed lists by person, rebuilt when lists change.
  Map<String, List<BlockHit>>? _hits;

  /// Objects shown anyway on this device, for now.
  final _shown = <String>{};

  void _load() {
    final scoped = node.store.setting('blockScopes');
    if (scoped is Map) {
      for (final MapEntry(key: person, value: spaces) in scoped.entries) {
        if (person is! String || spaces is! Map) continue;
        for (final MapEntry(key: space, value: v) in spaces.entries) {
          if (space is! String || v is! List || v.length != 2) continue;
          final state = ScopeState.values.asNameMap()[v[0]];
          if (state == null || v[1] is! int) continue;
          (_scoped[person] ??= {})[space] = (state, v[1] as int);
        }
      }
    }
    final subs = node.store.setting('blockSubs');
    if (subs is Map) {
      for (final MapEntry(:key, :value) in subs.entries) {
        if (key is! String || value is! Map) continue;
        final mode = ListMode.values.asNameMap()[value['mode']];
        if (mode == null || value['at'] is! int) continue;
        _subs[key] = (mode, value['at'] as int, value['removed'] == true);
      }
    }
  }

  void _save() {
    node.store.set('blockScopes', {
      for (final MapEntry(key: person, value: spaces) in _scoped.entries)
        person: {
          for (final MapEntry(key: space, value: (state, at)) in spaces.entries)
            space: [state.name, at],
        },
    });
    node.store.set('blockSubs', {
      for (final MapEntry(key: k, value: (mode, at, removed)) in _subs.entries)
        k: {'mode': mode.name, 'at': at, if (removed) 'removed': true},
    });
  }

  void _changed() {
    _version++;
    _digest = null;
  }

  // ---- Reading the policy -------------------------------------------------

  ScopeState _state(String person, String space) =>
      _scoped[person]?[space]?.$1 ?? ScopeState.none;

  /// The personal choice about [person] in [space] (not counting a block
  /// everywhere, which is [Node.blocked]).
  ScopeState scopeOf(String person, String space) => _state(person, space);

  /// Every space where a choice about [person] stands, with it.
  Map<String, ScopeState> scopesOf(String person) => {
    for (final MapEntry(:key, :value) in (_scoped[person] ?? const {}).entries)
      if (value.$1 != ScopeState.none) key: value.$1,
  };

  /// People with a choice standing somewhere, by person.
  Map<String, Map<String, ScopeState>> get scoped => {
    for (final person in _scoped.keys)
      if (scopesOf(person) case final s when s.isNotEmpty) person: s,
  };

  /// Whether this person blocked [person] everywhere or in [space].
  bool blockedIn(String person, String space) =>
      node.blocked.contains(person) ||
      (person != node.person && _state(person, space) == ScopeState.block);

  /// Whether this person muted [person] everywhere or in [space].
  bool mutedIn(String person, String space) =>
      person != node.person &&
      (_state(person, everywhere) == ScopeState.mute ||
          _state(person, space) == ScopeState.mute);

  /// Whether this person said lists may never hide [person].
  bool allowed(String person) => _state(person, everywhere) == ScopeState.allow;

  /// Whether [person] has a device admitted here.
  bool _admitted(String person) =>
      node.contacts.values.any((c) => c.person == person);

  Map<String, List<BlockHit>> get _index => _hits ??= _build();

  /// Entries about [person] on subscribed lists, in [space] when given,
  /// whether or not they apply (a friend's, an allowed person's).
  List<BlockHit> listHits(String person, [String? space]) => [
    for (final h in _index[person] ?? const <BlockHit>[])
      if (space == null || h.entry.covers(space)) h,
  ];

  /// The subscribed list entry that hides [person] in [space]: never for
  /// this person, an admitted friend or someone allowed.
  BlockHit? listHidden(String person, String space) {
    final hits = _index[person];
    if (hits == null || person == node.person) return null;
    if (allowed(person) || _admitted(person)) return null;
    BlockHit? found;
    for (final h in hits) {
      if (!h.entry.covers(space)) continue;
      if (h.mode == ListMode.block) return h;
      found ??= h;
    }
    return found;
  }

  /// Whether a list this person subscribes to in block mode keeps [person]
  /// out of [space].
  bool listBlocked(String person, String space) =>
      listHidden(person, space)?.mode == ListMode.block;

  /// Whether [person]'s objects in [space] are kept from view.
  bool hidden(String person, String space) =>
      blockedIn(person, space) ||
      mutedIn(person, space) ||
      listHidden(person, space) != null;

  /// Whether [o] is kept from view, unless shown anyway ([showAnyway]).
  bool hides(SignedObject o) =>
      hidden(o.author, o.space) && !_shown.contains(o.id);

  /// Whether [o] has been shown anyway on this device.
  bool shownAnyway(String id) => _shown.contains(id);

  /// Shows one hidden object on this device until the app restarts.
  void showAnyway(String id) {
    if (_shown.add(id)) {
      _changed();
      node.notify();
    }
  }

  /// Whether an object by [author] in [space] is taken in and passed on.
  /// Blocks everywhere keep it out wherever it is; a block in some spaces
  /// (personal, or a list in block mode) keeps it out there, except in a
  /// private group, where it only hides, so other members still get it.
  bool relays(String author, String space) {
    if (node.blocked.contains(author)) return false;
    if (author == node.person) return true;
    if (space.startsWith('room2:')) return true;
    return _state(author, space) != ScopeState.block &&
        !listBlocked(author, space);
  }

  /// Whether [person]'s governance records (ballots, delegations,
  /// proposals) in [space] are left out of this person's count.
  bool excludes(String person, String space) =>
      blockedIn(person, space) || listBlocked(person, space);

  /// Authors hidden in [space] besides [Node.blocked]: for unread counts.
  Set<String> hiddenAuthors(String space) => {
    ...node.blocked,
    for (final person in _scoped.keys)
      if (blockedIn(person, space) || mutedIn(person, space)) person,
    for (final person in _index.keys)
      if (listHidden(person, space) != null) person,
  };

  /// Whether anything besides [Node.blocked] is in force.
  bool get active =>
      _scoped.values.any((s) => s.values.any((v) => v.$1 != ScopeState.none)) ||
      _subs.values.any((s) => !s.$3);

  String? _digest;
  int _digestAt = -1;

  /// A stable summary of the policy, the same across restarts: for caches
  /// kept in storage. Equal to the old block-list key while nothing else is
  /// in force.
  String get digest {
    final v = version;
    if (_digest != null && _digestAt == v) return _digest!;
    _digestAt = v;
    final blocked = '${node.blocked.toList()..sort()}';
    if (!active && _shown.isEmpty) return _digest = blocked;
    return _digest = hash({
      'blocked': node.blocked.toList()..sort(),
      'scoped': scoped.map(
        (p, s) => MapEntry(p, s.map((k, v) => MapEntry(k, v.name))),
      ),
      'subs': {
        for (final MapEntry(:key, :value) in _subs.entries)
          if (!value.$3) key: value.$1.name,
      },
      'entries': {
        for (final MapEntry(:key, :value) in _index.entries)
          key: [for (final h in value) h.entry.created],
      },
      'shown': _shown.toList()..sort(),
    });
  }

  // ---- Lists --------------------------------------------------------------

  /// Subscribed lists by `owner/list`, with their mode.
  Map<(String, String), ListMode> get subscriptions => {
    for (final MapEntry(:key, :value) in _subs.entries)
      if (_split(key) case final k? when !value.$3) k: value.$1,
  };

  static (String, String)? _split(String key) {
    final slash = key.indexOf('/');
    return slash <= 0
        ? null
        : (key.substring(0, slash), key.substring(slash + 1));
  }

  /// [owner]'s lists this device holds, newest name first.
  List<BlockList> listsOf(String owner) {
    final found = <String, BlockList>{};
    for (final o in node.store.objects(kind: listKind, author: owner)) {
      final parsed = parseSpace(o.space);
      if (parsed == null || parsed.$1 != owner || !o.isPublic) continue;
      final p = _payload(o);
      if (p == null) continue;
      found.putIfAbsent(
        parsed.$2,
        () => BlockList(
          owner,
          parsed.$2,
          p['name'] as String,
          p['description'] as String? ?? '',
        ),
      );
    }
    return found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  /// The list [list] of [owner], if this device holds its name.
  BlockList? listInfo(String owner, String list) {
    final o = node.store.latestIn(listKind, space(owner, list));
    final p = o == null || o.author != owner ? null : _payload(o);
    if (p == null) return null;
    return BlockList(
      owner,
      list,
      p['name'] as String,
      p['description'] as String? ?? '',
    );
  }

  /// The current entries of [owner]'s [list], newest first.
  List<BlockEntry> entries(String owner, String list) {
    final seen = <String>{};
    final result = <BlockEntry>[];
    (int, String)? after;
    var read = 0;
    while (read < maxEntries) {
      final page = node.store.objects(
        kind: entryKind,
        space: space(owner, list),
        author: owner,
        after: after,
        limit: 500,
      );
      for (final o in page) {
        read++;
        final p = _payload(o);
        if (p == null || !seen.add(p['person'] as String)) continue;
        if (p['removed'] == true) continue;
        final scope = p['scope'];
        result.add(
          BlockEntry(
            owner,
            list,
            p['person'] as String,
            spaces: scope is List ? scope.cast<String>() : null,
            reason: p['reason'] as String?,
            evidence: [...?(p['evidence'] as List?)?.cast<String>()],
            created: o.created,
          ),
        );
      }
      if (page.length < 500) break;
      after = (page.last.created, page.last.id);
    }
    return result;
  }

  Json? _payload(SignedObject o) {
    if (!o.isPublic || !accepted(o) || node.blocked.contains(o.author)) {
      return null;
    }
    if (o.hasExpiry && o.expires <= node.now()) return null;
    final p = o.data['payload'];
    return p is Json && node.registry.accepts(o.kind, p) ? p : null;
  }

  Map<String, List<BlockHit>> _build() {
    final hits = <String, List<BlockHit>>{};
    for (final MapEntry(key: (owner, list), value: mode)
        in subscriptions.entries) {
      for (final e in entries(owner, list)) {
        (hits[e.person] ??= []).add(BlockHit(e, mode));
      }
    }
    return hits;
  }

  /// Creates (or renames) this person's public list called [name]. Returns
  /// the list's slug.
  Future<String> saveList(String name, {String description = ''}) async {
    final slug = PublicNames.slug(name);
    if (slug == null) throw StateError('That name cannot be a list');
    await node.publish(listKind, {
      'name': name.trim(),
      'description': description.trim(),
    }, space: space(node.person, slug));
    return slug;
  }

  /// Puts [person] on this person's [list], everywhere or in [spaces].
  Future<SignedObject> addEntry(
    String list,
    String person, {
    List<String>? spaces,
    String? reason,
    List<String> evidence = const [],
  }) {
    if (person == node.person) throw StateError('That is you');
    final why = reason?.trim() ?? '';
    return node.publish(entryKind, {
      'person': person,
      'scope': spaces ?? everywhere,
      if (why.isNotEmpty) 'reason': PublicNames.cap(why, maxReason),
      if (evidence.isNotEmpty) 'evidence': evidence.take(maxEvidence).toList(),
    }, space: space(node.person, list));
  }

  /// Takes [person] off this person's [list].
  Future<SignedObject> removeEntry(String list, String person) => node.publish(
    entryKind,
    {'person': person, 'scope': everywhere, 'removed': true},
    space: space(node.person, list),
  );

  /// Follows [owner]'s [list] in [mode] on all this person's devices.
  Future<void> subscribe(
    String owner,
    String list, {
    ListMode mode = ListMode.hide,
  }) async {
    final s = space(owner, list);
    if (!node.subscriptions.contains(s) &&
        node.subscriptions.length >= Node.maxSubscriptions) {
      throw StateError('You follow too many walls, forums, chats and lists');
    }
    final o = await node.publish(
      subKind,
      {'owner': owner, 'list': list, 'mode': mode.name},
      space: '_contacts',
      audience: [node.person],
    );
    _applySub(owner, list, mode, false, o.created);
  }

  /// Stops following [owner]'s [list] on all this person's devices.
  Future<void> unsubscribe(String owner, String list) async {
    final mode = _subs['$owner/$list']?.$1 ?? ListMode.hide;
    final o = await node.publish(
      subKind,
      {'owner': owner, 'list': list, 'mode': mode.name, 'removed': true},
      space: '_contacts',
      audience: [node.person],
    );
    _applySub(owner, list, mode, true, o.created);
  }

  void _applySub(
    String owner,
    String list,
    ListMode mode,
    bool removed,
    int at,
  ) {
    final key = '$owner/$list';
    if (_subs[key] case (_, final prior, _) when prior > at) return;
    _subs[key] = (mode, at, removed);
    _hits = null;
    _changed();
    _save();
    final s = space(owner, list);
    if (removed) {
      if (node.subscriptions.contains(s)) node.subscribe(s, false);
    } else if (!node.subscriptions.contains(s) &&
        node.subscriptions.length < Node.maxSubscriptions) {
      node.subscribe(s, true);
    }
    node.notify();
  }

  // ---- Personal choices ---------------------------------------------------

  /// Sets what this person chose about [person] in [spaces] (or
  /// [everywhere]), on all their devices. Blocking everywhere is
  /// [Node.setContactState] instead.
  Future<void> setScope(
    String person,
    List<String> spaces,
    ScopeState state,
  ) async {
    if (person == node.person) throw StateError('That is you');
    if (spaces.isEmpty || spaces.length > maxSpaces) {
      throw ArgumentError('1 to $maxSpaces spaces');
    }
    if (spaces.contains(everywhere) && state == ScopeState.block) {
      throw ArgumentError('A block everywhere is a contact_state');
    }
    if (state == ScopeState.allow &&
        !(spaces.length == 1 && spaces.single == everywhere)) {
      throw ArgumentError('Allowing is everywhere');
    }
    final o = await node.publish(
      scopeKind,
      {
        'person': person,
        'spaces': spaces,
        if (state == ScopeState.mute) 'mute': true,
        if (state == ScopeState.allow) 'allow': true,
        if (state == ScopeState.none) 'removed': true,
      },
      space: '_contacts',
      audience: [node.person],
    );
    _applyScope(person, spaces, state, o.created);
  }

  void _applyScope(
    String person,
    List<String> spaces,
    ScopeState state,
    int at,
  ) {
    final mine = _scoped[person] ??= {};
    var changed = false;
    for (final s in spaces) {
      if (mine[s] case (_, final prior) when prior > at) continue;
      mine[s] = (state, at);
      changed = true;
    }
    if (!changed) return;
    _changed();
    _save();
    node.notify();
  }

  /// Takes in a choice made on another of this person's devices.
  void received(SignedObject o, Json p) {
    if (o.author != node.person) return;
    if (o.kind == scopeKind) {
      final person = p['person'];
      if (person is! String || person == node.person) return;
      final state = p['removed'] == true
          ? ScopeState.none
          : p['allow'] == true
          ? ScopeState.allow
          : p['mute'] == true
          ? ScopeState.mute
          : ScopeState.block;
      _applyScope(
        person,
        (p['spaces'] as List).cast<String>(),
        state,
        o.created,
      );
    } else if (o.kind == subKind) {
      final mode = ListMode.values.asNameMap()[p['mode']] ?? ListMode.hide;
      _applySub(
        p['owner'] as String,
        p['list'] as String,
        mode,
        p['removed'] == true,
        o.created,
      );
    }
  }

  /// Notes a stored list or entry: a subscribed list's entries are read
  /// again when next needed.
  void stored(SignedObject o) {
    if (o.kind != entryKind && o.kind != listKind) return;
    final parsed = parseSpace(o.space);
    if (parsed == null) return;
    final sub = _subs['${parsed.$1}/${parsed.$2}'];
    if (sub == null || sub.$3) return;
    _hits = null;
    _changed();
  }
}
