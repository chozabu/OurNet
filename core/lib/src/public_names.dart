/// Names for public spaces. A public forum or chat is found by its name,
/// as on Reddit: everyone who types "cooking" is in the same place. Nothing
/// decides who owns a name, so two groups of friends who start "cooking"
/// without knowing of each other end up in one forum, and where that is not
/// wanted a more specific name or a private group does the job. See
/// SCOPES.md.
///
/// A forum's address is its name in lower case (the same shape as the old
/// named forums, so older builds read it as they do those). A chat's is
/// `chat:` and its name. Neither has an owner, so neither has anyone who can
/// remove another person's posts: blocking a sender is each person's own.
class PublicNames {
  static const maxLength = 60;

  /// Spaces that mean something else and so cannot be a forum's name.
  static const reserved = {'files'};

  /// [name] as an address: lower case, spaces as hyphens, only letters,
  /// digits, `-` and `_`. Null when nothing is left of it, it is too long,
  /// or it is reserved. `#Cooking Club` becomes `cooking-club`.
  static String? slug(String name) {
    var s = name.trim().toLowerCase();
    s = s.replaceFirst(RegExp(r'^(?:#+|r/)'), '');
    s = s.replaceAll(RegExp(r'\s+'), '-');
    s = s.replaceAll(RegExp(r'[^\p{L}\p{N}_-]+', unicode: true), '');
    s = s.replaceAll(RegExp(r'-{2,}'), '-');
    s = s.replaceAll(RegExp(r'^[-_]+|[-_]+$'), '');
    if (s.isEmpty || s.length > maxLength || reserved.contains(s)) return null;
    return s;
  }

  /// The address of the public forum called [name].
  static String? forumSpace(String name) => slug(name);

  /// The address of the public chat called [name].
  static String? chatSpace(String name) {
    final s = slug(name);
    return s == null ? null : 'chat:$s';
  }

  /// Whether [space] is the address of a public forum, whichever way it was
  /// named: a name, or an owner-bound `forum2:` address from before names.
  static bool isForumSpace(String space) =>
      space.isNotEmpty &&
      space.length <= 200 &&
      !space.startsWith('_') &&
      !space.startsWith('chat:') &&
      !reserved.contains(space) &&
      !RegExp(r'[\x00-\x1f]').hasMatch(space);

  /// The person who started the `forum2:` forum at [space]; null for any
  /// other.
  static String? forum2Owner(String space) {
    final m = RegExp(r'^forum2:([^:\s]+):([^:\s]+)$').firstMatch(space);
    return m?.group(1);
  }

  /// The forum a link or the user's own words name: an address as it is, or
  /// a name as [slug] makes it. Null when it is neither.
  static String? forumFrom(String text) {
    final t = text.trim();
    if (t.contains(':')) {
      return isForumSpace(t) && !RegExp(r'\s').hasMatch(t) ? t : null;
    }
    return slug(t);
  }

  /// [text] cut to [max] characters.
  static String cap(String text, int max) =>
      text.length > max ? text.substring(0, max) : text;
}
