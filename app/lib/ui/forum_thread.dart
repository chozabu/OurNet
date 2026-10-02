import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

/// One visible line of an open discussion, in reading order.
class ThreadRow {
  final SignedObject object;
  final int depth;

  /// The posts above this one, outermost first; '' where a parent is missing.
  final List<String> ancestors;

  /// Replies folded away beneath this post, at any depth.
  int hidden = 0;
  bool collapsed = false;

  /// Whether the row after this one is a reply to it (or its replies).
  bool hasChildren = false;
  ThreadRow(this.object, this.depth, this.ancestors);
}

/// Lays out [posts], which must already be in reading order (each post before
/// its replies), leaving out whatever sits beneath a collapsed post. The first
/// post of a discussion (depth 0) cannot be collapsed.
List<ThreadRow> threadRows(
  List<SignedObject> posts,
  int Function(SignedObject) depthOf,
  Set<String> collapsed,
) {
  final rows = <ThreadRow>[];
  final path = <String>[];
  ThreadRow? folded;
  for (final o in posts) {
    final depth = depthOf(o);
    if (folded != null) {
      if (depth > folded.depth) {
        folded.hidden++;
        continue;
      }
      folded = null;
    }
    if (path.length > depth) path.removeRange(depth, path.length);
    while (path.length < depth) {
      path.add('');
    }
    if (rows.isNotEmpty && depth > rows.last.depth) {
      rows.last.hasChildren = true;
    }
    final row = ThreadRow(o, depth, List.of(path));
    rows.add(row);
    path.add(o.id);
    if (depth > 0 && collapsed.contains(o.id)) {
      row.collapsed = true;
      folded = row;
    }
  }
  return rows;
}

/// "now", "5m", "3h", "2d", then the date.
String postAge(DateTime written, DateTime now) {
  final age = now.difference(written);
  if (age.inMinutes < 1) return 'now';
  if (age.inHours < 1) return '${age.inMinutes}m';
  if (age.inDays < 1) return '${age.inHours}h';
  if (age.inDays < 30) return '${age.inDays}d';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final date = '${written.day} ${months[written.month - 1]}';
  return written.year == now.year ? date : '$date ${written.year}';
}

/// A reply in a discussion, with Reddit-style structure and less chrome: a
/// header line (author, age, fold control), the text, and a footer line. The
/// avatar column of each ancestor continues down as a thread line; tapping a
/// line folds that ancestor's whole branch.
class ForumComment extends StatelessWidget {
  static const step = 24.0;
  final int depth;
  final List<String> ancestors;
  final String author, initial;
  final DateTime written;
  final bool unread, collapsed, hasChildren;
  final int hidden;

  /// How many ancestor lines fit; deeper branches keep only the nearest.
  final int maxLevels;
  final void Function(String id) onToggle;
  final String id;
  final String? title, scope;
  final List<Widget> body;
  final VoidCallback? onReply;
  final Widget? menu;
  const ForumComment({
    super.key,
    required this.id,
    required this.depth,
    required this.ancestors,
    required this.author,
    required this.initial,
    required this.written,
    required this.onToggle,
    this.unread = false,
    this.collapsed = false,
    this.hasChildren = false,
    this.hidden = 0,
    this.maxLevels = 6,
    this.title,
    this.scope,
    this.body = const [],
    this.onReply,
    this.menu,
  });

  static Color lineColor(ColorScheme scheme, int level) => [
    scheme.primary,
    scheme.tertiary,
    scheme.secondary,
    scheme.outline,
  ][level % 4];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final canFold = depth > 0;
    final shown = ancestors.length > maxLevels
        ? ancestors.sublist(ancestors.length - maxLevels)
        : ancestors;
    final skipped = ancestors.length - shown.length;
    final replies = hidden == 1 ? '1 reply' : '$hidden replies';
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < shown.length; i++)
            _ThreadLine(
              color: lineColor(scheme, skipped + i),
              onTap: shown[i].isEmpty ? null : () => onToggle(shown[i]),
            ),
          SizedBox(
            width: step,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 2),
                  child: CircleAvatar(
                    radius: 10,
                    backgroundColor: scheme.secondaryContainer,
                    foregroundColor: scheme.onSecondaryContainer,
                    child: Text(initial, style: const TextStyle(fontSize: 11)),
                  ),
                ),
                if (hasChildren && !collapsed)
                  Expanded(
                    child: _ThreadLine(
                      color: lineColor(scheme, skipped + shown.length),
                      onTap: canFold ? () => onToggle(id) : null,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(top: 2, bottom: 2),
              padding: const EdgeInsets.only(left: 4, right: 4, bottom: 2),
              decoration: unread
                  ? BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(6),
                    )
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: canFold ? () => onToggle(id) : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          if (unread)
                            Padding(
                              padding: const EdgeInsets.only(right: 5),
                              child: Icon(
                                Icons.circle,
                                size: 7,
                                color: scheme.primary,
                              ),
                            ),
                          Flexible(
                            child: Text(
                              author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Tooltip(
                            message: written.toLocal().toString().substring(
                              0,
                              16,
                            ),
                            child: Text(
                              ' · ${postAge(written, DateTime.now())}',
                              style: muted,
                            ),
                          ),
                          if (collapsed && hidden > 0)
                            Flexible(
                              child: Text(
                                ' · $replies',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: muted,
                              ),
                            ),
                          const Spacer(),
                          if (canFold)
                            Icon(
                              collapsed ? Icons.unfold_more : Icons.unfold_less,
                              size: 16,
                              semanticLabel: collapsed
                                  ? 'Show replies'
                                  : 'Fold replies',
                              color: scheme.onSurfaceVariant,
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (!collapsed) ...[
                    if (title != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(title!, style: theme.textTheme.titleLarge),
                      ),
                    ...body,
                    SizedBox(
                      height: 30,
                      child: Row(
                        children: [
                          if (onReply != null)
                            TextButton.icon(
                              onPressed: onReply,
                              icon: const Icon(Icons.reply, size: 15),
                              label: const Text('Reply'),
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 28),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                visualDensity: VisualDensity.compact,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                textStyle: theme.textTheme.labelMedium,
                              ),
                            ),
                          ?menu,
                          if (scope != null)
                            Flexible(
                              child: Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Text(
                                  scope!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: muted,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A vertical line the width of one avatar column, thickening under the
/// pointer to show that it can be tapped.
class _ThreadLine extends StatefulWidget {
  final Color color;
  final VoidCallback? onTap;
  const _ThreadLine({required this.color, required this.onTap});
  @override
  State<_ThreadLine> createState() => _ThreadLineState();
}

class _ThreadLineState extends State<_ThreadLine> {
  bool hovered = false;
  @override
  Widget build(BuildContext context) {
    final tappable = widget.onTap != null;
    return MouseRegion(
      cursor: tappable ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox(
          width: ForumComment.step,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: hovered && tappable ? 3 : 2,
              decoration: BoxDecoration(
                color: widget.color.withValues(
                  alpha: hovered && tappable ? 0.95 : 0.4,
                ),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
