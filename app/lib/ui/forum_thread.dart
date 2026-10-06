import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

import 'avatar.dart';

/// One visible line of an open discussion, in reading order.
class ThreadRow {
  final SignedObject object;
  final int depth;

  /// The posts above this one, outermost first; '' where a parent is missing.
  final List<String> ancestors;

  /// Per ancestor: whether its thread line carries on below this row, because
  /// it has another reply still to come. The nearest ancestor's line always
  /// bends into this row; this says whether it also continues past it.
  List<bool> through = const [];

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
  // Walking back up: a branch continues past a row while a later row, still
  // inside that ancestor's replies, sits one level below the ancestor.
  final later = <bool>[];
  for (final row in rows.reversed) {
    row.through = [
      for (var k = 0; k < row.depth; k++) k + 1 < later.length && later[k + 1],
    ];
    if (later.length > row.depth + 1) later.length = row.depth + 1;
    while (later.length <= row.depth) {
      later.add(false);
    }
    later[row.depth] = true;
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

/// A reply in a discussion, laid out like Reddit's: an avatar on the left with
/// the header and text beside it, a footer line, and a thread line that bends
/// from each parent into its replies. The ⊖ / ⊕ button (or the line itself)
/// folds a branch. The reply box opens in place under the comment.
class ForumComment extends StatelessWidget {
  static const step = 24.0;
  static const _avatar = 10.0, _avatarTop = 8.0;
  final int depth;
  final List<String> ancestors;
  final List<bool> through;
  final String author, initial;

  /// The author's profile picture, shown instead of [initial].
  final Avatar? avatar;
  final DateTime written;
  final bool unread, collapsed, hasChildren, replying;
  final int hidden;

  /// How many ancestor lines fit; deeper branches keep only the nearest.
  final int maxLevels;
  final void Function(String id) onToggle;
  final String id;
  final String? title, scope;
  final List<Widget> body;
  final VoidCallback? onReply;
  final Widget? menu;

  /// The reply box, when this comment is the one being answered.
  final Widget? reply;
  const ForumComment({
    super.key,
    required this.id,
    required this.depth,
    required this.ancestors,
    required this.through,
    required this.author,
    required this.initial,
    this.avatar,
    required this.written,
    required this.onToggle,
    this.unread = false,
    this.collapsed = false,
    this.hasChildren = false,
    this.replying = false,
    this.hidden = 0,
    this.maxLevels = 6,
    this.title,
    this.scope,
    this.body = const [],
    this.onReply,
    this.menu,
    this.reply,
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
    final skipped = ancestors.length > maxLevels
        ? ancestors.length - maxLevels
        : 0;
    final shown = ancestors.sublist(skipped);

    List<Widget> rails({required bool bend}) => [
      for (var i = 0; i < shown.length; i++)
        _Rail(
          color: lineColor(scheme, skipped + i),
          surface: scheme.surface,
          through: i + skipped < through.length && through[i + skipped],
          bend: bend && i == shown.length - 1,
          onTap: shown[i].isEmpty ? null : () => onToggle(shown[i]),
        ),
    ];

    Widget foldButton() => SizedBox(
      width: step,
      height: step,
      child: IconButton(
        tooltip: collapsed ? 'Show replies' : 'Fold replies',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: step, height: step),
        iconSize: 20,
        color: scheme.onSurfaceVariant,
        onPressed: () => onToggle(id),
        icon: Icon(
          collapsed ? Icons.add_circle_outline : Icons.remove_circle_outline,
        ),
      ),
    );

    final replies = hidden == 1 ? '1 reply' : '$hidden replies';
    final header = InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: canFold && collapsed ? () => onToggle(id) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            if (unread)
              Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Icon(Icons.circle, size: 7, color: scheme.primary),
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
              message: written.toLocal().toString().substring(0, 16),
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
          ],
        ),
      ),
    );

    final top = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...rails(bend: true),
          SizedBox(
            width: step,
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: EdgeInsets.only(
                  top: collapsed ? _avatarTop - 2 : _avatarTop,
                ),
                child: collapsed
                    ? foldButton()
                    : ProfileAvatar(
                        avatar: avatar,
                        label: initial,
                        radius: _avatar,
                        backgroundColor: scheme.secondaryContainer,
                        foregroundColor: scheme.onSecondaryContainer,
                      ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 4, right: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  header,
                  if (!collapsed) ...[
                    if (title != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(title!, style: theme.textTheme.titleLarge),
                      ),
                    ...body,
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
    if (collapsed) return top;

    final bottom = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...rails(bend: false),
          SizedBox(
            width: step,
            child: Column(
              children: [
                SizedBox(
                  height: step + 3,
                  child: canFold
                      ? Align(
                          alignment: Alignment.bottomCenter,
                          child: foldButton(),
                        )
                      : null,
                ),
                if (hasChildren)
                  Expanded(
                    child: _Rail(
                      color: lineColor(scheme, ancestors.length),
                      surface: scheme.surface,
                      through: true,
                      onTap: canFold ? () => onToggle(id) : null,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                left: 4,
                right: 4,
                bottom: depth <= 1 ? 8 : 2,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                              textStyle: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: replying ? FontWeight.w800 : null,
                              ),
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
                  ?reply,
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return Column(children: [top, bottom]);
  }
}

/// One avatar-wide column of a thread line. [through] runs the full height;
/// [bend] curves in from the top towards the avatar of the comment beside it,
/// as Reddit's branches do. The line thickens under the pointer when it can
/// be tapped to fold the branch.
class _Rail extends StatefulWidget {
  final Color color, surface;
  final bool through, bend;
  final VoidCallback? onTap;
  const _Rail({
    required this.color,
    required this.surface,
    required this.onTap,
    this.through = false,
    this.bend = false,
  });
  @override
  State<_Rail> createState() => _RailState();
}

class _RailState extends State<_Rail> {
  bool hovered = false;
  @override
  Widget build(BuildContext context) {
    if (!widget.through && !widget.bend) {
      return const SizedBox(width: ForumComment.step);
    }
    final tappable = widget.onTap != null;
    final lit = hovered && tappable;
    return MouseRegion(
      cursor: tappable ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox(
          width: ForumComment.step,
          child: CustomPaint(
            painter: _RailPainter(
              color: lit
                  ? widget.color
                  : Color.alphaBlend(
                      widget.color.withValues(alpha: 0.45),
                      widget.surface,
                    ),
              width: lit ? 3 : 2,
              through: widget.through,
              bend: widget.bend,
            ),
          ),
        ),
      ),
    );
  }
}

class _RailPainter extends CustomPainter {
  final Color color;
  final double width;
  final bool through, bend;
  const _RailPainter({
    required this.color,
    required this.width,
    required this.through,
    required this.bend,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    const bendAt = ForumComment._avatarTop + ForumComment._avatar;
    const radius = 8.0;
    final path = Path();
    if (through) {
      path
        ..moveTo(x, 0)
        ..lineTo(x, size.height);
    }
    if (bend) {
      path
        ..moveTo(x, 0)
        ..lineTo(x, bendAt - radius)
        ..quadraticBezierTo(x, bendAt, x + radius, bendAt)
        ..lineTo(size.width + 1, bendAt);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.color != color ||
      old.width != width ||
      old.through != through ||
      old.bend != bend;
}
