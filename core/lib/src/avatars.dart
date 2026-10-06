import 'dart:convert';
import 'dart:typed_data';

import 'model.dart';
import 'node.dart';

/// A person's profile picture, as they last published it.
class Avatar {
  /// The object that carried it: a stable key for image caches, which
  /// changes whenever the picture does.
  final String id;

  /// A JPEG or PNG at most [Avatars.edge] pixels square.
  final Uint8List bytes;
  final int created;
  const Avatar(this.id, this.bytes, this.created);
}

/// Profile pictures: a public `avatar` object in `_identity`, like the
/// `profile` that carries the name, so anyone who can see someone's name
/// can see their picture. The newest one decides; one without an image
/// removes the picture. Builds before it drop the kind, as they drop any
/// public object outside the spaces they follow.
///
/// Lookups are cached per person and cleared only when that person's
/// pictures change, so lists cost one query and one decode per person per
/// session, however long the history.
class Avatars {
  /// Pixels along each side; enough for the largest place one is shown
  /// (a call screen) on a dense phone screen.
  static const edge = 256;

  /// Encoded size limit; a 256 pixel photo is usually 15–25 KB.
  static const maxBytes = 48 * 1024;
  static const space = '_identity';

  final Node node;
  final _cache = <String, Avatar?>{};
  Avatars(this.node);

  /// [person]'s picture, or null when they have none or are blocked.
  Avatar? of(String person) {
    if (node.blocked.contains(person)) return null;
    return _cache.putIfAbsent(person, () => _load(person));
  }

  Avatar? _load(String person) {
    // Newest first. Blocking is checked by [of], so this never caches a
    // blocked person's absence.
    for (final o in node.store.objects(
      kind: 'avatar',
      space: space,
      author: person,
      limit: 4,
    )) {
      if (!o.isPublic || !node.visible(o)) continue;
      return decodeAvatar(o);
    }
    return null;
  }

  /// Called by the node when one of [person]'s pictures is stored.
  void changed(String person) => _cache.remove(person);

  /// Publishes a picture from straight RGBA pixels, at most [edge] square.
  /// Compression runs off this isolate.
  Future<SignedObject> set(Uint8List rgba, int width, int height) async {
    final encoded = await node.blobs.encodeAvatar(
      rgba,
      width,
      height,
      maxBytes: maxBytes,
    );
    return node.publish('avatar', {
      'image': base64Encode(encoded),
      'type': 'image/jpeg',
    }, space: space);
  }

  /// Removes this person's picture. Copies others already received stay in
  /// their databases, but are no longer shown.
  Future<SignedObject> clear() => node.publish('avatar', {}, space: space);
}

/// The picture [o] carries, or null for a removal or anything unreadable.
Avatar? decodeAvatar(SignedObject o) {
  final image = o.data['payload']['image'];
  if (image is! String) return null;
  try {
    final bytes = base64Decode(image);
    final jpeg =
        bytes.length > 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
    final png =
        bytes.length > 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47;
    if (!jpeg && !png) return null;
    return Avatar(o.id, bytes, o.created);
  } on FormatException {
    return null;
  }
}
