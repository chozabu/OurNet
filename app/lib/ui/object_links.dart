import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

/// What forum, post and message links in text need from the app: whether the
/// space is joined, a line of what the link points at when this device holds
/// it, and how to follow one. Placed above the whole app, beside [ChatLinks],
/// so a link in any message, post or note can be followed.
class ObjectLinks extends InheritedWidget {
  final bool Function(String space) joined;
  final String? Function(ObjectLink link) preview;
  final Future<void> Function(ObjectLink link) open;
  const ObjectLinks({
    super.key,
    required this.joined,
    required this.preview,
    required this.open,
    required super.child,
  });

  static ObjectLinks? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ObjectLinks>();

  @override
  bool updateShouldNotify(ObjectLinks oldWidget) => false;
}

/// A forum, post or chat message link as a chip: what it points at, and a
/// tap to join its space if need be and open it.
class ObjectLinkChip extends StatelessWidget {
  final String link;
  final TextStyle? style;
  const ObjectLinkChip(this.link, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final parsed = Links.parse(link);
    if (parsed == null) return Text(link, style: style);
    final links = ObjectLinks.maybeOf(context);
    final joined = links?.joined(parsed.space) ?? false;
    final scheme = Theme.of(context).colorScheme;
    final label = switch (parsed.type) {
      'forum' => parsed.space.startsWith('forum2:') ? 'Forum' : parsed.space,
      'post' => links?.preview(parsed) ?? parsed.title ?? 'Forum post',
      _ => links?.preview(parsed) ?? 'Chat message',
    };
    final icon = switch (parsed.type) {
      'forum' => Icons.forum_outlined,
      'post' => Icons.article_outlined,
      _ => Icons.chat_bubble_outline,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: links == null ? null : () => links.open(parsed),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: scheme.onTertiaryContainer),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (style ?? const TextStyle()).copyWith(
                      fontWeight: FontWeight.w600,
                      color: scheme.onTertiaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  joined ? 'Open' : 'Join',
                  style: (style ?? const TextStyle()).copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
