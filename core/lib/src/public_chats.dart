import 'model.dart';
import 'node.dart';
import 'note_state.dart';
import 'public_names.dart';
import 'registry.dart';

/// One message in a public chat, as a list shows it.
typedef ChatMessage = ({
  SignedObject object,
  String text,
  int sent,
  String? reply,

  /// The name the sender gave, which nothing checks: shown beside their key
  /// where this device knows no name for them.
  String? name,
});

/// Public chats: named, open conversations that anyone can start and anyone
/// with the address can join, like public forums but read as a chat
/// (RetroShare's chat lobbies are the model). See SCOPES.md.
///
/// A chat's address is `chat:<creator>:<random>`. Two kinds live in it, both
/// public: `chat` names it (only the creator's counts, as the address names
/// them) and `chat_msg` is one message. Older builds keep and pass on kinds
/// they do not know without reading them. Messages travel as other public
/// objects do: to friends subscribed to the space, who pass them on to
/// theirs.
class PublicChats {
  static const recordKind = 'chat';
  static const messageKind = 'chat_msg';

  /// The creator taking a message out of their chat: `{object}`. Only the
  /// creator's count, as for a chat's name.
  static const hideKind = 'chat_hide';
  static const prefix = 'chat:';

  /// The kinds public chats own, and how their content is checked.
  static const module = Module(
    'public_chats',
    kinds: {
      recordKind: _validChat,
      messageKind: _validChatMsg,
      hideKind: _validChatHide,
    },
  );

  // A public chat's name, and one message in it: see `PublicChats`.
  static bool _validChat(Json p) =>
      p['name'] is String &&
      (p['name'] as String).trim().isNotEmpty &&
      (p['name'] as String).length <= 100 &&
      (p['description'] == null ||
          p['description'] is String &&
              (p['description'] as String).length <= 4000);

  static bool _validChatMsg(Json p) =>
      p['text'] is String &&
      (p['reply'] == null || p['reply'] is String) &&
      (p['sent'] == null || p['sent'] is int) &&
      (p['name'] == null ||
          p['name'] is String && (p['name'] as String).length <= 100);

  static bool _validChatHide(Json p) => p['object'] is String;

  final Node node;
  final NoteState state;
  PublicChats(this.node, this.state);

  /// A chat is one with an owner (`chat:<creator>:<random>`) or, since public
  /// names, one called by name (`chat:<name>`). See [PublicNames].
  static bool isChat(String space) =>
      creatorOf(space) != null || slugOf(space) != null;

  /// The name of the public chat at [space] when it is called by name, which
  /// nobody owns; null for any other space.
  static String? slugOf(String space) {
    if (!space.startsWith(prefix)) return null;
    final name = space.substring(prefix.length);
    return name.isNotEmpty &&
            !name.contains(':') &&
            PublicNames.slug(name) == name
        ? name
        : null;
  }

  /// The person who started the chat at [space], or null for any other
  /// space.
  static String? creatorOf(String space) {
    if (!space.startsWith(prefix)) return null;
    final parts = space.split(':');
    return parts.length == 3 && parts[1].isNotEmpty && parts[2].isNotEmpty
        ? parts[1]
        : null;
  }

  bool owns(String space) => creatorOf(space) == node.person;

  /// A link to the chat at [space], to send to people: their app shows it as
  /// a chip that joins and opens it. [name] lets the chip name the chat
  /// before its record has reached them.
  static String link(String space, {String? name}) {
    // A chat called by name is linked by that name.
    final slug = slugOf(space);
    if (slug != null) return 'ournet://chat/${Uri.encodeComponent(slug)}';
    return 'ournet://chat/${Uri.encodeComponent(space)}'
        '${name == null || name.isEmpty ? '' : '?name=${Uri.encodeQueryComponent(name)}'}';
  }

  /// The chat a [link] names, and the name it carries; null if it is not a
  /// chat link.
  static ({String space, String? name})? parseLink(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'ournet' || uri.host != 'chat') {
      return null;
    }
    final parts = uri.pathSegments;
    if (parts.length != 1) return null;
    // `ournet://chat/cooking` names the chat called cooking.
    final space = isChat(parts.single)
        ? parts.single
        : PublicNames.chatSpace(parts.single);
    if (space == null || !isChat(space)) return null;
    final name = uri.queryParameters['name']?.trim();
    return (
      space: space,
      name: name == null || name.isEmpty
          ? null
          : name.length > 100
          ? name.substring(0, 100)
          : name,
    );
  }

  /// Chat links in [text].
  static final linkPattern = RegExp(
    r'ournet://chat/[^\s<>"\x27]+[^\s<>"\x27.,;:!?)\]}]',
  );

  /// The chats this person has joined.
  List<String> get joined => [
    for (final space in node.subscriptions)
      if (isChat(space)) space,
  ]..sort();

  /// Starts a chat called [name] and joins it. Returns its address.
  Future<String> create(String name, {String description = ''}) async {
    final title = name.trim();
    if (title.isEmpty || title.length > 100) {
      throw ArgumentError('A public chat needs a name of up to 100 letters');
    }
    final space = '$prefix${node.person}:${randomId()}';
    await node.publish(recordKind, {
      'name': title,
      'description': description.trim(),
    }, space: space);
    await state.subscribe(space, true);
    return space;
  }

  /// Starts the public chat called [name], or joins it if it exists: a name
  /// is the address, so everyone who types it is in the same chat. Returns
  /// its address.
  Future<String> startOrJoin(String name) async {
    final space = PublicNames.chatSpace(name);
    if (space == null) {
      throw ArgumentError('A public chat needs a name of letters or digits');
    }
    await state.subscribe(space, true);
    return space;
  }

  /// Joins the chat at [address] (or a chat link): its messages sync from
  /// now on.
  Future<String> join(String address) async {
    final text = address.trim();
    final space =
        parseLink(text)?.space ??
        (isChat(text) ? text : PublicNames.chatSpace(text) ?? text);
    if (!isChat(space)) {
      throw ArgumentError('That is not a public chat address');
    }
    await state.subscribe(space, true);
    return space;
  }

  Future<void> leave(String space) => state.subscribe(space, false);

  /// The chat's name and description, from its creator's latest record; null
  /// until that has arrived.
  ({String name, String description})? info(String space) =>
      infoOf(node, space);

  /// [info], for code without a [PublicChats] (notifications).
  static ({String name, String description})? infoOf(Node node, String space) {
    final creator = creatorOf(space);
    if (creator == null) {
      final named = slugOf(space);
      return named == null ? null : (name: named, description: '');
    }
    for (final o in node.store.objects(
      kind: recordKind,
      space: space,
      author: creator,
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

  /// Sends [text]. [name] is the sender's display name, for readers who do
  /// not know them.
  Future<SignedObject> send(
    String space,
    String text, {
    String? reply,
    String? name,
  }) {
    final body = text.trim();
    if (body.isEmpty) throw ArgumentError('Nothing to send');
    if (!isChat(space)) throw ArgumentError('Not a public chat');
    return node.publish(messageKind, {
      'text': body,
      'sent': DateTime.now().millisecondsSinceEpoch,
      'reply': ?reply,
      if (name != null && name.trim().isNotEmpty)
        'name': name.trim().length > 100
            ? name.trim().substring(0, 100)
            : name.trim(),
    }, space: space);
  }

  /// Messages newest first, [limit] at most, read through the
  /// (kind, space, created) index: what a chat window shows, never the
  /// whole history.
  List<ChatMessage> latest(String space, {int limit = 100}) {
    final hidden = this.hidden(space);
    return [
      for (final o in node.store.objects(
        kind: messageKind,
        space: space,
        limit: limit,
      ))
        if (!hidden.contains(o.id))
          if (message(o) case final m?) m,
    ];
  }

  /// Messages the chat's creator took out.
  Set<String> hidden(String space) {
    final creator = creatorOf(space);
    if (creator == null) return const {};
    return {
      for (final o in node.store.objects(
        kind: hideKind,
        space: space,
        author: creator,
        limit: 5000,
      ))
        if (o.isPublic)
          if (o.data['payload'] case {'object': final String id}) id,
    };
  }

  /// Takes [message] out of [space], for everyone who updates: only for the
  /// chat's creator.
  Future<void> hide(String space, String message) async {
    if (!owns(space)) {
      throw StateError(
        'Only the person who started a chat can remove messages',
      );
    }
    await node.publish(hideKind, {'object': message}, space: space);
  }

  /// [o] as a message, or null when it is not one this device shows.
  ChatMessage? message(SignedObject o) {
    if (o.kind != messageKind || !o.isPublic || !node.visible(o)) return null;
    final p = o.data['payload'];
    if (p is! Json || p['text'] is! String) return null;
    return (
      object: o,
      text: p['text'] as String,
      sent: p['sent'] as int? ?? o.created,
      reply: p['reply'] as String?,
      name: p['name'] as String?,
    );
  }

  /// Whether this device notifies about new messages in [space]. Off unless
  /// asked for: an open chat can be busy.
  bool notifies(String space) => notifiesIn(node, space);
  static bool notifiesIn(Node node, String space) =>
      node.store.setting('chatNotify/$space') == true;
  void setNotifies(String space, bool on) =>
      node.store.set('chatNotify/$space', on ? true : null);

  /// When this device last read [space]: messages after it are unread.
  int seenUpTo(String space) =>
      node.store.setting('chatSeen/$space') as int? ?? 0;

  /// Messages by others since this device last read [space].
  int unread(String space) => node.store.countAfter(
    messageKind,
    space,
    seenUpTo(space),
    except: {node.person, ...node.blocked},
  );

  /// Marks everything in [space] read on this device.
  void markRead(String space) {
    final newest = node.store.latestIn(messageKind, space);
    if (newest != null && newest.created > seenUpTo(space)) {
      node.store.set('chatSeen/$space', newest.created);
    }
  }
}
