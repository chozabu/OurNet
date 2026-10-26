/// The kinds compiled into this build and how their content is checked,
/// grouped by the feature that owns them. Plugins declare theirs the same way
/// at run time: see [Registry] and docs/PLUGINS.md.
library;

import 'locations.dart' show LocationChoice;
import 'model.dart';
import 'recurrence.dart' show Repeat;
import 'registry.dart';

/// Shared and personal notes: see `Notes`.
const notesModule = Module(
  'notes',
  kinds: {'note_op': _noteOp, 'note_self': _noteSelf},
);

bool _noteOp(Json p) =>
    p['epoch'] is String &&
    _register(p) &&
    _noteValue(p['field'] as String, p['value'], p) &&
    (p['checkpoint'] == null || p['checkpoint'] is bool);

bool _noteSelf(Json p) =>
    p['target'] is String &&
    (p['target'] as String).length <= 200 &&
    _register(p) &&
    _selfValue(p['field'] as String, p['value']);

/// Public forums and private group forums: see `RoomForum`.
const forumsModule = Module(
  'forums',
  kinds: {
    'forum': _forum,
    'forum_hide': _forumHide,
    'post': _post,
    'room_post': _roomPost,
  },
);

bool _forum(Json p) =>
    p['name'] is String &&
    (p['name'] as String).trim().isNotEmpty &&
    (p['name'] as String).length <= 100 &&
    p['description'] is String &&
    (p['description'] as String).length <= 4000;

bool _forumHide(Json p) => p['object'] is String;

bool _post(Json p) =>
    p['text'] is String &&
    (p['title'] == null ||
        (p['title'] is String && (p['title'] as String).length <= 200));

/// A discussion post in a private group's forum: like `post`, but private
/// to the group, so it is its own kind and builds without it ignore it.
bool _roomPost(Json p) =>
    (p['text'] is String || p['chunks'] is List) &&
    (p['title'] == null ||
        (p['title'] is String && (p['title'] as String).length <= 200)) &&
    (p['parent'] == null || p['parent'] is String) &&
    (p['history'] == null || p['history'] is bool) &&
    (p['originalAuthor'] == null || p['originalAuthor'] is String) &&
    (p['copyOf'] == null || p['copyOf'] is String) &&
    (p['sent'] == null || p['sent'] is int);

/// A person's posts for their friends, with comments: see `Wall`. Who may
/// write each kind, and where, is checked by `Walls.accepted`.
const wallModule = Module(
  'wall',
  kinds: {
    'wall_post': _wallPost,
    'wall_comment': _wallComment,
    'wall_hide': _forumHide,
    'wall_key': _wallKey,
  },
);

/// Public (`text`, optional `title` and `share`), or sealed with a wall key.
bool _wallPost(Json p) => p['box'] != null
    ? _wallSealed(p) && p['text'] == null
    : _text(p['text'], 20000) &&
          (p['title'] == null || _text(p['title'], 200)) &&
          (p['share'] == null ||
              p['share'] is Map && (p['share'] as Map)['object'] is Map);

/// On `post`: in the clear (`text`, optional `parent`) on a public post, or
/// sealed with the post's epoch key.
bool _wallComment(Json p) =>
    _text(p['post'], 128) &&
    (p['box'] != null
        ? _wallSealed(p) && p['text'] == null
        : _text(p['text'], 20000));

bool _wallSealed(Json p) =>
    p['epoch'] is int &&
    p['epoch'] >= 0 &&
    p['epoch'] < 9007199254740991 &&
    _text(p['box'], 200000) &&
    (p['aead'] == null || p['aead'] == aeadAlgorithm);

/// A wall's key for one epoch: 32 bytes, base64.
bool _wallKey(Json p) =>
    p['epoch'] is int &&
    p['epoch'] >= 0 &&
    p['epoch'] < 9007199254740991 &&
    p['key'] is String &&
    (p['key'] as String).length == 44;

/// Votes and delegations on posts: see `Voting`.
const votingModule = Module(
  'voting',
  kinds: {'vote': _vote, 'delegate': _delegate},
);

bool _vote(Json p) => p['object'] is String && [-1, 0, 1].contains(p['value']);

bool _delegate(Json p) => p['person'] is String;

/// Friends' adverts for public forums and chats: see `Listings`.
const listingsModule = Module('listings', kinds: {'listing': _listing});

/// A friend's advert for a public forum or chat they follow: see
/// `Listings`. `off` takes an earlier one down.
bool _listing(Json p) =>
    p['space'] is String &&
    (p['space'] as String).isNotEmpty &&
    (p['space'] as String).length <= 200 &&
    (p['off'] == null || p['off'] is bool) &&
    (p['off'] == true ||
        ['forum', 'chat'].contains(p['type']) &&
            p['name'] is String &&
            (p['name'] as String).trim().isNotEmpty &&
            (p['name'] as String).length <= 100 &&
            (p['description'] == null ||
                p['description'] is String &&
                    (p['description'] as String).length <= 500));

/// Signed plugin releases and the packages that carry them: see
/// `PluginRelease` and docs/STORE-PLAN.md.
const pluginReleasesModule = Module(
  'plugin_releases',
  kinds: {'plugin_release': _pluginRelease, 'plugin_package': _pluginPackage},
);

/// What a publisher signed about one version: who it is, what it may reach,
/// and the digest of its contents.
bool _pluginRelease(Json p) =>
    p['id'] is String &&
    PluginKinds.id.hasMatch(p['id']) &&
    _line(p['version'], 32) &&
    _line(p['api'], 8) &&
    _line(p['name'], 50) &&
    _text(p['summary'], 500) &&
    _sha256.hasMatch('${p['digest']}') &&
    _sha256.hasMatch('${p['manifest']}') &&
    _names(p['grants'], 8) &&
    _names(p['kinds'], 32) &&
    (p['changes'] == null || _text(p['changes'], 4096));

/// A release and the chunks of one encoding of its package (the shared
/// file fields are checked for every kind).
bool _pluginPackage(Json p) =>
    p['release'] is Map &&
    p['chunks'] is List &&
    p['size'] is int &&
    p['size'] <= 32 * 1024 * 1024;

bool _line(Object? v, int limit) =>
    v is String && v.trim().isNotEmpty && v.length <= limit;

bool _names(Object? v, int limit) =>
    v is List &&
    v.length <= limit &&
    v.every((n) => n is String && _pluginName.hasMatch(n));

final _sha256 = RegExp(r'^[0-9a-f]{64}$');
final _pluginName = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

/// Private groups: membership, keys and their shared items. See `Everyday` and `GroupAccess`.
const groupsModule = Module(
  'groups',
  kinds: {
    'keys': _keys,
    'room': _room,
    'room_invite': _roomInvite,
    'room_add': _roomAdd,
    'room_leave': _roomLeave,
    'room_read': _roomRead,
    'inbox': _inbox,
    'room_item': _inbox,
  },
);

/// Content keys for objects written before one of this person's devices
/// existed, re-wrapped for their devices: see [Node.shareKeys].
bool _keys(Json p) =>
    p['keys'] is List &&
    (p['keys'] as List).length <= maxGrantKeys &&
    (p['keys'] as List).every(
      (k) =>
          k is Map &&
          k['object'] is String &&
          (k['object'] as String).length <= 128 &&
          k['key'] is String &&
          (k['key'] as String).length <= 64,
    );

bool _room(Json p) =>
    p['room'] is String &&
    p['owner'] is String &&
    p['name'] is String &&
    (p['name'] as String).trim().isNotEmpty &&
    (p['name'] as String).length <= 100 &&
    p['members'] is List &&
    (p['members'] as List).length <= 64 &&
    (p['members'] as List).every((v) => v is String) &&
    (p['generation'] == null ||
        p['generation'] is int &&
            p['generation'] >= 0 &&
            p['generation'] < 9007199254740991) &&
    (p['epoch'] == null || p['epoch'] is String) &&
    (p['archived'] == null || p['archived'] is bool) &&
    (p['certificates'] == null ||
        p['certificates'] is List &&
            (p['certificates'] as List).length <= 256 &&
            (p['certificates'] as List).every((c) => c is Map)) &&
    // Optional: who may add people (`members`, or absent for the owner
    // alone), and the key everything addressed to the group also opens
    // with. Builds without them ignore both.
    (p['invite'] == null || p['invite'] == 'members') &&
    (p['groupKey'] == null || validGroupKey(p['groupKey']));

/// A member adding people to a group whose owner lets members do so: see
/// `Everyday.invite`. Carries their devices and the group's key.
bool _roomInvite(Json p) => _roomAdd(p) && validGroupKey(p['groupKey']);

/// A member asking a group's owner to add people: see `Everyday.askToAdd`.
bool _roomAdd(Json p) =>
    p['epoch'] is String &&
    _ids(p['people'], 16) &&
    (p['people'] as List).isNotEmpty &&
    p['certificates'] is List &&
    (p['certificates'] as List).length <= 128 &&
    (p['certificates'] as List).every((c) => c is Map);

bool _roomLeave(Json p) => p['epoch'] is String;

/// This person's other devices learn which of a group's messages are read.
bool _roomRead(Json p) => p['space'] is String && p['upTo'] is int;

bool _inbox(Json p) =>
    p['entry'] is String &&
    p['clock'] is int &&
    p['clock'] >= 0 &&
    p['clock'] < 9007199254740991 &&
    ['note', 'file', 'check', 'pin'].contains(p['type']) &&
    (!['note', 'check'].contains(p['type']) || p['text'] is String) &&
    (p['deleted'] == null || p['deleted'] is bool) &&
    // Optional, for group chat: the entry replied to, and when the
    // entry was first written (an edit is a newer object).
    (p['reply'] == null || p['reply'] is String) &&
    (p['sent'] == null || p['sent'] is int) &&
    (p['type'] != 'file' || p['chunks'] is List) &&
    (p['type'] != 'check' || (p['done'] is bool && p['list'] is String)) &&
    (p['type'] != 'pin' || (p['target'] is String && p['pinned'] is bool));

/// Direct messages and what is said about them.
const messagesModule = Module(
  'messages',
  kinds: {
    'message': _message,
    'file': _file,
    'delivery': _delivery,
    'read': _read,
    'read_state': _readState,
    'reaction': _reaction,
    'message_edit': _messageEdit,
    'message_delete': _messageDelete,
  },
);

bool _message(Json p) =>
    (p['text'] is String || p['chunks'] is List) &&
    (p['reply'] == null || p['reply'] is String) &&
    (p['forwarded'] == null || p['forwarded'] is bool);

bool _file(Json p) => p['chunks'] is List;

bool _delivery(Json p) => p['object'] is String;

/// `objects` (optional) marks several messages read at once; builds that
/// predate it mark only `object`, the newest of them.
bool _read(Json p) =>
    p['object'] is String &&
    (p['objects'] == null ||
        p['objects'] is List &&
            (p['objects'] as List).length <= 200 &&
            (p['objects'] as List).every((v) => v is String));

/// What a linking device had read, for the device it linked: see
/// `Node.shareReadState`.
bool _readState(Json p) =>
    p['device'] is String &&
    p['upTo'] is int &&
    p['unread'] is List &&
    (p['unread'] as List).length <= 1500 &&
    (p['unread'] as List).every((v) => v is String) &&
    (p['chats'] == null ||
        p['chats'] is Map &&
            (p['chats'] as Map).length <= 500 &&
            (p['chats'] as Map).values.every((v) => v is int));

/// An empty emoji withdraws the author's reaction.
bool _reaction(Json p) =>
    p['object'] is String &&
    p['emoji'] is String &&
    (p['emoji'] as String).length <= 32;

bool _messageEdit(Json p) => p['object'] is String && p['text'] is String;

bool _messageDelete(Json p) => p['object'] is String;

/// Private drive entries: see `Drive`.
const driveModule = Module('drive', kinds: {'drive': _drive});

/// Path separators and control characters, which a file name must not hold.
final _unsafeName = RegExp(r'[/\\\x00-\x1f]');

bool _drive(Json p) =>
    p['entry'] is String &&
    p['revision'] is String &&
    p['parents'] is List &&
    (p['parents'] as List).length <= 128 &&
    (p['parents'] as List).every((v) => v is String) &&
    p['name'] is String &&
    (p['name'] as String).trim().isNotEmpty &&
    (p['name'] as String).length <= 255 &&
    !_unsafeName.hasMatch(p['name']) &&
    (p['folder'] == null || p['folder'] is String) &&
    p['deleted'] is bool &&
    ['file', 'folder'].contains(p['type']) &&
    (p['type'] == 'folder' || p['chunks'] is List);

/// Who people are, their devices and who they know.
const peopleModule = Module(
  'people',
  kinds: {
    'profile': _profile,
    'avatar': _avatar,
    'device_name': _deviceName,
    'sealed_root': _sealedRoot,
    'contact_state': _contactState,
    'friends': _friends,
    'connect': _connect,
  },
);

bool _profile(Json p) =>
    p['name'] is String &&
    (p['name'] as String).isNotEmpty &&
    (p['name'] as String).length <= 100;

/// A profile picture: see `Avatars`. One without an image removes it.
bool _avatar(Json p) =>
    p['image'] == null ||
    (p['image'] is String &&
        (p['image'] as String).length <= 64 * 1024 &&
        ['image/jpeg', 'image/png'].contains(p['type']));

/// A newer name for one of the author's devices: see `Node.renameDevice`.
bool _deviceName(Json p) =>
    p['device'] is String &&
    (p['device'] as String).length <= 64 &&
    p['label'] is String &&
    (p['label'] as String).trim().isNotEmpty &&
    (p['label'] as String).length <= 100;

/// Which copy of the root a device holds: see `Node.announceRootCopy`.
bool _sealedRoot(Json p) {
  if (p['changed'] is! bool) return false;
  try {
    SealedRoot.fromJson(p['sealedRoot']);
    return true;
  } on FormatException {
    return false;
  }
}

/// Blocking or disconnecting, shared among the author's own devices.
bool _contactState(Json p) =>
    p['person'] is String &&
    (p['person'] as String).length <= 64 &&
    ['friend', 'blocked', 'unblocked', 'forgotten'].contains(p['state']);

/// Who the author is connected to, and their devices: see `Connections`.
bool _friends(Json p) =>
    _ids(p['friends'], 1000) &&
    p['devices'] is List &&
    (p['devices'] as List).length <= 32 &&
    (p['devices'] as List).every((c) => c is Map);

/// Asking someone to connect, or saying yes: see `Connections`.
bool _connect(Json p) =>
    ['request', 'accept'].contains(p['type']) &&
    p['devices'] is List &&
    (p['devices'] as List).length <= 32 &&
    (p['devices'] as List).every((c) => c is Map) &&
    (p['type'] != 'accept' || p['request'] is String) &&
    (p['via'] == null || _ids(p['via'], 8));

/// Calendar events and replies: see `Calendar`.
const calendarModule = Module(
  'calendar',
  kinds: {'cal_event': _calEvent, 'cal_rsvp': _calRsvp},
);

bool _calRsvp(Json p) =>
    p['event'] is String &&
    (p['event'] as String).length <= 160 &&
    ['yes', 'no', 'maybe', 'none'].contains(p['response']) &&
    (p['instance'] == null ||
        p['instance'] is String && (p['instance'] as String).length <= 40);

/// Shared positions: see `Locations`.
const locationsModule = Module('locations', kinds: {'location': _location});

/// Saved map places, lists, list memberships and strictly personal notes.
const placesModule = Module(
  'places',
  kinds: {
    'map_place': _mapPlace,
    'map_list': _mapList,
    'map_link': _mapLink,
    'map_note': _mapNote,
  },
);
bool _mapRegister(Json p) =>
    _line(p['id'], 500) &&
    p['clock'] is int &&
    p['clock'] >= 0 &&
    p['clock'] < 9007199254740000 &&
    (p['deleted'] == null || p['deleted'] is bool) &&
    (p['history'] == null || p['history'] is bool);
bool _mapList(Json p) => _mapRegister(p) && _line(p['name'], 100);
bool _mapPlace(Json p) =>
    _mapRegister(p) &&
    _line(p['name'], 200) &&
    _line(p['emoji'], 32) &&
    p['note'] is String &&
    p['note'].length <= 4000 &&
    p['lat'] is int &&
    p['lat'].abs() <= 900000000 &&
    p['lng'] is int &&
    p['lng'].abs() <= 1800000000;
bool _mapLink(Json p) =>
    _mapRegister(p) &&
    _line(p['place'], 200) &&
    _line(p['list'], 200) &&
    p['id'] == '${p['place']}|${p['list']}';
bool _mapNote(Json p) =>
    _mapRegister(p) && p['note'] is String && p['note'].length <= 4000;

bool _location(Json p) =>
    p['lat'] is String &&
    p['lng'] is String &&
    (double.tryParse(p['lat'])?.abs() ?? double.infinity) <= 90 &&
    (double.tryParse(p['lng'])?.abs() ?? double.infinity) <= 180;

/// A list of at most [limit] person IDs.
bool _ids(Object? v, int limit) =>
    v is List &&
    v.length <= limit &&
    v.every((p) => p is String && p.length <= 64);

final _calDay = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// A calendar event, or a new version of one: see `Calendar`. Anything an
/// older build does not know is kept and passed on without being read.
bool _calEvent(Json p) {
  bool within(String key, int limit) =>
      p[key] == null || p[key] is String && (p[key] as String).length <= limit;
  if (p['event'] is! String ||
      (p['event'] as String).isEmpty ||
      (p['event'] as String).length > 160 ||
      p['clock'] is! int ||
      p['clock'] < 0 ||
      p['clock'] >= 9007199254740991 ||
      (p['deleted'] != null && p['deleted'] is! bool) ||
      !within('title', 300) ||
      !within('desc', 8000) ||
      !within('loc', 300) ||
      !within('url', 500) ||
      !within('tz', 64) ||
      !within('transcript', 65536) ||
      (p['color'] != null &&
          !(p['color'] is String && _colorName.hasMatch(p['color']))) ||
      (p['busy'] != null && p['busy'] is! bool) ||
      (p['sent'] != null && p['sent'] is! int) ||
      (p['history'] != null && p['history'] is! bool) ||
      (p['originalAuthor'] != null && p['originalAuthor'] is! String) ||
      (p['series'] == null) != (p['instance'] == null) ||
      !within('series', 160) ||
      !within('instance', 40) ||
      (p['repeat'] != null &&
          !(p['repeat'] is Map && Repeat.valid(p['repeat']))) ||
      (p['reminders'] != null &&
          !(p['reminders'] is List &&
              (p['reminders'] as List).length <= 5 &&
              (p['reminders'] as List).every(
                (m) => m is int && m >= 0 && m <= 40320 * 4,
              ))) ||
      (p['audio'] != null && p['audio'] is! Map) ||
      (p['audio'] != null && p['chunks'] is! List)) {
    return false;
  }
  if (p['deleted'] == true) return true;
  if (p['allDay'] == true) {
    final day = p['day'];
    if (day is! String || !_calDay.hasMatch(day)) return false;
    final parsed = DateTime.tryParse(day);
    return parsed != null &&
        p['days'] is int &&
        p['days'] >= 1 &&
        p['days'] <= 3660;
  }
  return p['start'] is int &&
      p['end'] is int &&
      p['start'] >= 0 &&
      p['end'] >= p['start'] &&
      p['end'] < 253402300799999 &&
      p['end'] - p['start'] <= 3660 * 86400000;
}

/// Register fields: a name, or `name:<id>:name` for per-item values. Names
/// this build does not know are accepted with a bounded value, so newer builds
/// can add fields that older ones keep, replicate and simply do not display.
final _fieldName = RegExp(
  r'^[a-z][a-zA-Z0-9]{0,31}(:[a-zA-Z0-9_-]{1,80}:[a-z][a-zA-Z0-9]{0,31})?$',
);
// Order keys never end in '0', so a later key can always be placed before
// one: see `orderBetween`. Keys that do are rejected rather than stored.
final _orderKey = RegExp(r'^[0-9A-Za-z]{0,63}[1-9A-Za-z]$');
final _colorName = RegExp(r'^[a-z]{1,16}$');

bool _register(Json p) =>
    p['field'] is String &&
    _fieldName.hasMatch(p['field']) &&
    p['clock'] is int &&
    p['clock'] >= 0 &&
    p['clock'] < 9007199254740991 &&
    p['parents'] is List &&
    (p['parents'] as List).length <= 128 &&
    (p['parents'] as List).every((v) => v is String && v.length <= 128) &&
    (p['request'] == null ||
        p['request'] is String && (p['request'] as String).length <= 100);

bool _text(Object? v, [int limit = 16384]) => v is String && v.length <= limit;
bool _bounded(Object? v) {
  if (v is String) return v.length <= 16384;
  if (v is bool || v is int) return true;
  if (v is! Map && v is! List) return false;
  try {
    return bytes(v).length <= 8192;
  } catch (_) {
    return false;
  }
}

/// Known shared-note registers keep strict types; see `Notes` for meaning.
bool _noteValue(String field, Object? v, Json p) {
  final parts = field.split(':');
  final name = parts.last;
  if (parts.length == 1) {
    return switch (field) {
      'title' || 'text' => _text(v),
      'deleted' => v is bool,
      'color' ||
      'background' ||
      'format' => v is String && _colorName.hasMatch(v),
      'created' || 'edited' => v is int && v >= 0 && v < 253402300799999,
      _ => _bounded(v),
    };
  }
  if (parts.first == 'check') {
    return switch (name) {
      'text' => _text(v),
      'done' || 'deleted' => v is bool,
      'order' => v is String && _orderKey.hasMatch(v),
      'indent' => v is int && v >= 0 && v <= 1,
      _ => _bounded(v),
    };
  }
  if (parts.first == 'file') {
    return switch (name) {
      // The attachment itself: encrypted chunks travel in this same payload.
      'meta' =>
        v is Map &&
            _bounded(v) &&
            ['audio', 'image', 'drawing'].contains(v['kind']) &&
            p['chunks'] is List,
      'strokes' => v is Map && _bounded(v) && p['chunks'] is List,
      'transcript' => _text(v),
      'deleted' => v is bool,
      'order' => v is String && _orderKey.hasMatch(v),
      _ => _bounded(v),
    };
  }
  return _bounded(v);
}

/// Personal note state, readable only by this person's own devices.
bool _selfValue(String field, Object? v) => switch (field) {
  'pin' || 'archive' || 'labelDeleted' || 'noAdvert' => v is bool,
  // The removal (operation ID) this person emptied from Removed.
  'purged' => v is String && v.length <= 128,
  // The device that shares this person's position with friends ('' for none).
  'locationPrimary' => v is String && v.length <= 128,
  // How much of this person's position one friend is sent, and when
  // per-friend levels were set up.
  'locationLevel' => LocationChoice.parse(v) != null,
  'locationLevelsFrom' => v is int && v >= 0,
  'order' || 'rank' => v is String && _orderKey.hasMatch(v),
  'labelName' => v is String && v.trim().isNotEmpty && v.length <= 50,
  'labels' =>
    v is List &&
        v.length <= 64 &&
        v.every((l) => l is String && l.length <= 64),
  'reminder' =>
    v is Map &&
        _bounded(v) &&
        (v.isEmpty ||
            (v['at'] is int &&
                v['at'] >= 0 &&
                [
                  'none',
                  'daily',
                  'weekly',
                  'monthly',
                  'yearly',
                ].contains(v['repeat'] ?? 'none'))),
  _ => _bounded(v),
};
