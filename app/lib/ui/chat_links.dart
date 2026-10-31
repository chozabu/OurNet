import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

/// What public chat links in text need from the app: whether a chat is
/// joined, and how to join and open one. Placed above the whole app, beside
/// [EventLinks], so a link in any message or post can be followed.
class ChatLinks extends InheritedWidget {
  final bool Function(String space) joined;
  final Future<void> Function(String space) open;
  const ChatLinks({
    super.key,
    required this.joined,
    required this.open,
    required super.child,
  });

  static ChatLinks? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatLinks>();

  @override
  bool updateShouldNotify(ChatLinks oldWidget) => false;
}

/// A public chat link as a chip: the chat's name and a tap to join or open
/// it.
class ChatLinkChip extends StatelessWidget {
  final String link;
  final TextStyle? style;
  const ChatLinkChip(this.link, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final parsed = PublicChats.parseLink(link);
    if (parsed == null) return Text(link, style: style);
    final links = ChatLinks.maybeOf(context);
    final joined = links?.joined(parsed.space) ?? false;
    return LinkChip(
      icon: Icons.public,
      label: parsed.name ?? 'Public chat',
      joined: joined,
      style: style,
      onTap: links == null ? null : () => links.open(parsed.space),
    );
  }
}

/// A link in text drawn as a chip: what it points at, and Join or Open.
class LinkChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool joined;
  final TextStyle? style;
  final VoidCallback? onTap;
  const LinkChip({
    super.key,
    required this.icon,
    required this.label,
    required this.joined,
    this.style,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
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
