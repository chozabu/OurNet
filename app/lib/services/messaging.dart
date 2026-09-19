import 'package:ournet_core/ournet_core.dart';

/// Messaging shared by the app and by work done without it (notification
/// replies handled in the background).

/// The friend chosen to carry messages to [recipient], if still usable.
List<String> messageHelpers(Node node, String recipient) {
  final helper = node.store.setting('messageHelper/$recipient');
  return helper is String &&
          helper != recipient &&
          helper != node.person &&
          !node.blocked.contains(helper) &&
          node.contacts.values.any((c) => c.person == helper)
      ? [helper]
      : const [];
}

Future<SignedObject> sendMessage(Node node, String recipient, String text) =>
    node.publish(
      'message',
      {'text': text.trim()},
      space: '_messages',
      audience: [recipient],
      via: messageHelpers(node, recipient),
    );

/// One line describing a message or post: its title, text, a voice
/// transcript, or the attachment's name. Empty when there is nothing to show.
String contentPreview(Json? content) {
  if (content == null) return '';
  if (content['title'] case final String title when title.isNotEmpty) {
    return title;
  }
  final text = (content['text'] ?? '').toString();
  if (text.isNotEmpty) return text;
  if (content['audio'] != null) {
    return '🎤 ${content['transcript'] ?? 'Voice message'}';
  }
  return (content['name'] ?? '').toString();
}

/// The latest name [person] published for themselves, if any.
String? profileName(Node node, String person) {
  for (final o in node.store.objects(
    kind: 'profile',
    space: '_identity',
    author: person,
    limit: 8,
  )) {
    if (o.isPublic && node.visible(o) && o.data['payload']['name'] is String) {
      return o.data['payload']['name'] as String;
    }
  }
  return null;
}

/// Whether [o] defines a forum: public and signed by the forum's owner.
bool isForumDefinition(Node node, SignedObject o) =>
    o.kind == 'forum' &&
    o.isPublic &&
    o.space.startsWith('forum2:${o.author}:') &&
    node.visible(o);
