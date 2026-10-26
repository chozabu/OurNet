import 'model.dart';
import 'node.dart';
import 'public_chats.dart';
import 'public_names.dart';
import 'wall.dart';

/// A link to a public forum, a post in one, a message in a public chat, or a
/// person's wall or a post on it.
typedef ObjectLink = ({
  /// `forum`, `post`, `message` or `wall`.
  String type,
  String space,

  /// The post or message; null for a forum or a whole wall.
  String? object,
  String? title,
});

/// `ournet://` links to things in public spaces, shown in any message, post
/// or note as a chip that opens the thing. Chat and event links have their
/// own parsers ([PublicChats.parseLink], `Calendar.parseLink`).
///
/// - `ournet://forum/<name>`: the public forum called that. A forum's name
///   is its address, so the link is the same for everyone.
/// - `ournet://post/<space>/<id>`: one post, with an optional `?title=`.
/// - `ournet://message/<space>/<id>`: one message in a public chat.
/// - `ournet://wall/<person>`: a person's wall, to follow it; with `/<id>`,
///   one post on it.
///
/// A link to a post or message names its space so that a device not in it can
/// join first. Links to things only some people can read (a note, a message
/// in a group) work the same way but show as unavailable to anyone else, as
/// event links do.
class Links {
  static String forum(String space) =>
      'ournet://forum/${Uri.encodeComponent(space)}';

  static String post(String space, String id, {String? title}) =>
      _object('post', space, id, title);

  static String message(String space, String id) =>
      _object('message', space, id, null);

  static String wall(String person, {String? post}) =>
      'ournet://wall/${Uri.encodeComponent(person)}'
      '${post == null ? '' : '/${Uri.encodeComponent(post)}'}';

  static String _object(String type, String space, String id, String? title) {
    final t = title?.trim() ?? '';
    return 'ournet://$type/${Uri.encodeComponent(space)}/'
        '${Uri.encodeComponent(id)}'
        '${t.isEmpty ? '' : '?title=${Uri.encodeQueryComponent(PublicNames.cap(t, 100))}'}';
  }

  /// Links of these kinds in [text].
  static final pattern = RegExp(
    r'ournet://(?:forum|post|message|wall)/[^\s<>"\x27]+[^\s<>"\x27.,;:!?)\]}]',
  );

  static bool _plainId(String id) =>
      id.isNotEmpty && id.length <= 200 && !RegExp(r'[\s\x00-\x1f]').hasMatch(id);

  /// What [link] names, or null if it is not a forum, post, message or wall
  /// link.
  static ObjectLink? parse(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'ournet') return null;
    final parts = uri.pathSegments;
    switch (uri.host) {
      case 'forum':
        if (parts.length != 1) return null;
        final space = PublicNames.forumFrom(parts.single);
        return space == null
            ? null
            : (type: 'forum', space: space, object: null, title: null);
      case 'post':
      case 'message':
        if (parts.length != 2 || !_plainId(parts[1])) return null;
        final space = uri.host == 'post'
            ? PublicNames.forumFrom(parts[0])
            : (PublicChats.isChat(parts[0]) ? parts[0] : null);
        if (space == null) return null;
        final title = uri.queryParameters['title']?.trim();
        return (
          type: uri.host,
          space: space,
          object: parts[1],
          title: title == null || title.isEmpty
              ? null
              : PublicNames.cap(title, 100),
        );
      case 'wall':
        if (parts.isEmpty || parts.length > 2 || !_plainId(parts[0])) {
          return null;
        }
        if (parts.length == 2 && !_plainId(parts[1])) return null;
        return (
          type: 'wall',
          space: Walls.space(parts[0]),
          object: parts.length == 2 ? parts[1] : null,
          title: null,
        );
    }
    return null;
  }

  /// A line of the post or message [link] names, if this device holds it and
  /// it is public; null otherwise (not synced yet, removed, or private).
  static String? preview(Node node, ObjectLink link) {
    final id = link.object;
    if (id == null) return null;
    final o = node.store.get(id);
    final kind = switch (link.type) {
      'post' => 'post',
      'wall' => Walls.postKind,
      _ => PublicChats.messageKind,
    };
    if (o == null ||
        o.space != link.space ||
        !o.isPublic ||
        !node.visible(o) ||
        o.kind != kind ||
        !Walls.accepted(o)) {
      return null;
    }
    final p = o.data['payload'];
    // A friends-only wall post is sealed: its link previews nothing.
    if (p is! Json || Walls.sealed(p)) return null;
    final text = p['title'] ?? p['text'];
    return text is String && text.trim().isNotEmpty
        ? PublicNames.cap(text.trim().replaceAll(RegExp(r'\s+'), ' '), 140)
        : null;
  }
}
