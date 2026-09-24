import 'model.dart';
import 'node.dart';

/// Reactions, edits and deletions of private messages.
///
/// Each is its own encrypted object pointing at the message it changes, so
/// builds that predate them store and replicate them but keep showing the
/// original. Their target is only known after decryption, so this keeps a
/// small local index in settings, consumed in arrival order from a cursor:
/// the cost follows new records, never the length of history. Records whose
/// message has not arrived yet are indexed anyway and checked when shown.
class MessageUpdates {
  final Node node;
  MessageUpdates(this.node);

  static const kinds = ['reaction', 'message_edit', 'message_delete'];

  Future<void>? _running;
  bool _again = false;

  /// Indexes everything stored since the last call. Concurrent calls share
  /// one pass, which repeats once if more arrived meanwhile.
  Future<void> catchUp() {
    _again = true;
    return _running ??= () async {
      try {
        while (_again) {
          _again = false;
          for (final kind in kinds) {
            await _consume(kind);
          }
        }
      } finally {
        _running = null;
      }
    }();
  }

  Future<void> _consume(String kind) async {
    final key = 'messageUpdates/$kind';
    var cursor = node.store.setting(key) as int? ?? 0;
    while (true) {
      final page = node.store.objectsAfter(kind, cursor);
      if (page.isEmpty) return;
      for (final (rowid, o) in page) {
        cursor = rowid;
        final p = await node.content(o);
        if (p != null) _apply(o, p);
      }
      node.store.set(key, cursor);
      if (page.length < 256) return;
    }
  }

  void _apply(SignedObject o, Json p) {
    final target = p['object'] as String;
    switch (o.kind) {
      case 'reaction':
        final key = 'reactions/$target';
        final all = Map<String, dynamic>.from(
          node.store.setting(key) as Map? ?? const {},
        );
        final previous = all[o.author];
        if (previous is Map && (previous['created'] as int) > o.created) return;
        all[o.author] = {'emoji': p['emoji'], 'created': o.created};
        node.store.set(key, all);
      case 'message_edit':
        final key = 'edited/$target';
        final previous = node.store.setting(key);
        if (previous is Map &&
            previous['author'] == o.author &&
            (previous['created'] as int) > o.created) {
          return;
        }
        node.store.set(key, {
          'author': o.author,
          'text': p['text'],
          'created': o.created,
        });
      case 'message_delete':
        final key = 'deleted/$target';
        if (node.store.setting(key) is Map) return;
        node.store.set(key, {'author': o.author, 'created': o.created});
    }
  }

  /// Emoji per person who reacted to [message] and may see it.
  Map<String, String> reactions(SignedObject message) {
    final all = node.store.setting('reactions/${message.id}');
    if (all is! Map) return const {};
    return {
      for (final MapEntry(:key, :value) in all.entries)
        if (value is Map &&
            value['emoji'] is String &&
            (value['emoji'] as String).isNotEmpty &&
            (key == message.author || message.audience.contains(key)) &&
            !node.blocked.contains(key))
          key as String: value['emoji'] as String,
    };
  }

  /// The replacement text its author gave [message], if any.
  String? editedText(SignedObject message) {
    final edit = node.store.setting('edited/${message.id}');
    return edit is Map && edit['author'] == message.author
        ? edit['text'] as String?
        : null;
  }

  /// Whether the author deleted [message] for everyone.
  bool deleted(SignedObject message) {
    final record = node.store.setting('deleted/${message.id}');
    return record is Map && record['author'] == message.author;
  }

  /// Whether this person removed [message] from their own view only.
  bool hidden(SignedObject message) =>
      node.store.setting('hidden/${message.id}') == true;

  /// [payload] with its author's edit applied, or null when deleted.
  Json? current(SignedObject message, Json payload) {
    if (deleted(message)) return null;
    final text = editedText(message);
    return text == null ? payload : {...payload, 'text': text};
  }

  Future<SignedObject> react(SignedObject message, String emoji) =>
      _publish('reaction', message, {'emoji': emoji});

  Future<SignedObject> edit(SignedObject message, String text) {
    if (message.author != node.person) {
      throw StateError('Only your own messages can be edited');
    }
    return _publish('message_edit', message, {'text': text.trim()});
  }

  Future<SignedObject> deleteForEveryone(SignedObject message) {
    if (message.author != node.person) {
      throw StateError('Only your own messages can be deleted for everyone');
    }
    return _publish('message_delete', message, const {});
  }

  /// Hides [message] on this device only; settings are not shared. It is
  /// also marked read so it no longer counts as unread.
  Future<void> hide(SignedObject message) async {
    node.store.set('hidden/${message.id}', true);
    if (message.author != node.person) await node.markRead(message.id);
    node.notify();
  }

  Future<SignedObject> _publish(
    String kind,
    SignedObject message,
    Json fields,
  ) async {
    final object = await node.publish(
      kind,
      {'object': message.id, ...fields},
      space: '_messages',
      audience: message.audience.where((p) => p != node.person).toList(),
    );
    await catchUp();
    node.notify();
    return object;
  }
}
