import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';
import 'note_colors.dart';
import 'note_editor.dart' show PersonAvatar;

/// A Keep-style card for a note summary (`type: shared_note`). Checkbox taps
/// are reported immediately; [overrides] holds values not yet in the summary.
class NoteCard extends StatefulWidget {
  final EverydayItem item;
  final bool pinned;
  final Map<String, bool> overrides;
  final String Function(String person) personName;
  final VoidCallback onOpen;
  final void Function(String item, bool done) onCheck;
  final void Function(Offset? position) onMenu;
  const NoteCard({
    super.key,
    required this.item,
    required this.pinned,
    required this.overrides,
    required this.personName,
    required this.onOpen,
    required this.onCheck,
    required this.onMenu,
  });
  @override
  State<NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends State<NoteCard> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final p = widget.item.data;
    final theme = Theme.of(context);
    final color = noteColor(context, p['color']);
    final title = (p['title'] as String? ?? '').trim();
    final body = (p['body'] as String? ?? '').trim();
    final checks = (p['checks'] as List? ?? const []).cast<Map>();
    final more = p['moreUnchecked'] as int? ?? 0;
    final checked = p['checkedCount'] as int? ?? 0;
    final people = (p['people'] as List? ?? const []).cast<String>();
    final empty = title.isEmpty && body.isEmpty && checks.isEmpty;
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: Material(
        color: color ?? theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: color == null
              ? BorderSide(color: theme.colorScheme.outlineVariant)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onOpen,
          onLongPress: () => widget.onMenu(null),
          onSecondaryTapUp: (details) => widget.onMenu(details.globalPosition),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (title.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 24, bottom: 6),
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (body.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(
                          right: title.isEmpty ? 24 : 0,
                          bottom: checks.isEmpty ? 0 : 6,
                        ),
                        child: Text(
                          body,
                          maxLines: 10,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (empty)
                      Text(
                        p['removed'] == true ? 'Removed note' : 'Empty note',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (p['deleted'] != true)
                      for (final row in checks)
                        _CheckRow(
                          text: row['text'],
                          done: widget.overrides[row['id']] ?? false,
                          onChanged: (v) => widget.onCheck(row['id'], v),
                        ),
                    if (more > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 4, top: 2),
                        child: Text(
                          '+ $more more',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    if (checked > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 4, top: 2),
                        child: Text(
                          '$checked checked item${checked == 1 ? '' : 's'}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    if (p['conflicts'] == true ||
                        people.length > 1 ||
                        p['removed'] == true)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (people.length > 1)
                              for (final person in people.take(5))
                                PersonAvatar(
                                  name: widget.personName(person),
                                  radius: 12,
                                ),
                            if (p['conflicts'] == true)
                              Tooltip(
                                message: 'Competing edits to review',
                                child: Icon(
                                  Icons.call_split,
                                  size: 18,
                                  color: theme.colorScheme.error,
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.pinned || hover)
                Positioned(
                  top: 2,
                  right: 2,
                  child: IconButton(
                    tooltip: 'More',
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    onPressed: () => widget.onMenu(null),
                    icon: Icon(
                      hover ? Icons.more_vert : Icons.push_pin,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final String text;
  final bool done;
  final ValueChanged<bool> onChanged;
  const _CheckRow({
    required this.text,
    required this.done,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 32,
        height: 28,
        child: Checkbox(
          value: done,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onChanged: (v) => onChanged(v ?? false),
        ),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            text.isEmpty ? ' ' : text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: done
                ? TextStyle(
                    decoration: TextDecoration.lineThrough,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )
                : null,
          ),
        ),
      ),
    ],
  );
}
