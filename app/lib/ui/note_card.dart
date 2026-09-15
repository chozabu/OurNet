import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart' show Files;
import 'inline_image.dart';
import 'note_colors.dart';
import 'note_editor.dart' show PersonAvatar;
import 'note_markup.dart';
import 'note_organise.dart';
import 'voice_recorder.dart' show formatDuration;

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

  /// Personal organisation shown as chips.
  final List<String> labels;
  final Json? reminder;

  /// Selection for bulk actions: a check appears on hover or while selecting.
  final bool selected;
  final bool selecting;
  final VoidCallback? onSelect;

  /// Needed to show the first photo or drawing.
  final Files? files;
  final SignedObject? Function(String id)? objectOf;
  final bool online;
  const NoteCard({
    super.key,
    required this.item,
    required this.pinned,
    required this.overrides,
    required this.personName,
    required this.onOpen,
    required this.onCheck,
    required this.onMenu,
    this.labels = const [],
    this.reminder,
    this.selected = false,
    this.selecting = false,
    this.onSelect,
    this.files,
    this.objectOf,
    this.online = false,
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
    final markup = p['format'] == 'markup';
    final body = (p['body'] as String? ?? '').trim();
    final transcript = (p['transcript'] as String? ?? '').trim();
    final checks = (p['checks'] as List? ?? const []).cast<Map>();
    final more = p['moreUnchecked'] as int? ?? 0;
    final checked = p['checkedCount'] as int? ?? 0;
    final people = (p['people'] as List? ?? const []).cast<String>();
    final files = (p['files'] as List? ?? const []).cast<Map>();
    final picture = files
        .where((f) => f['kind'] == 'image' || f['kind'] == 'drawing')
        .firstOrNull;
    final pictures = files
        .where((f) => f['kind'] == 'image' || f['kind'] == 'drawing')
        .length;
    final recordings = files.where((f) => f['kind'] == 'audio').toList();
    final object = picture == null
        ? null
        : widget.objectOf?.call(picture['object'] as String);
    final empty =
        title.isEmpty &&
        body.isEmpty &&
        checks.isEmpty &&
        transcript.isEmpty &&
        files.isEmpty;
    final selectable = widget.onSelect != null;
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: Material(
        color: color ?? theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: widget.selected
              ? BorderSide(color: theme.colorScheme.primary, width: 2.5)
              : color == null
              ? BorderSide(color: theme.colorScheme.outlineVariant)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.selecting && selectable
              ? widget.onSelect
              : widget.onOpen,
          onLongPress: selectable ? widget.onSelect : () => widget.onMenu(null),
          onSecondaryTapUp: (details) => widget.onMenu(details.globalPosition),
          child: NoteBackground(
            name: p['background'] as String?,
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (object != null && widget.files != null)
                      Stack(
                        children: [
                          InlineImage(
                            key: ValueKey(object.id),
                            files: widget.files!,
                            object: object,
                            payload: picture!.cast<String, dynamic>(),
                            online: widget.online,
                            height: 150,
                            fit: BoxFit.cover,
                            radius: 0,
                            onTap: widget.selecting && selectable
                                ? widget.onSelect
                                : widget.onOpen,
                          ),
                          if (pictures > 1)
                            Positioned(
                              right: 8,
                              bottom: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '+${pictures - 1}',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                            ),
                        ],
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (title.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(
                                right: 24,
                                bottom: 6,
                              ),
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
                              child: MarkupText(
                                body,
                                markup: markup,
                                maxLines: 10,
                              ),
                            ),
                          if (empty)
                            Text(
                              p['removed'] == true
                                  ? 'Removed note'
                                  : 'Empty note',
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          if (p['deleted'] != true)
                            for (final row in checks)
                              _CheckRow(
                                text: row['text'],
                                indent: row['indent'] as int? ?? 0,
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
                          for (final recording in recordings.take(2))
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.play_circle_outline,
                                    size: 20,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    formatDuration(
                                      recording['duration'] as int? ?? 0,
                                    ),
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          if (transcript.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                transcript,
                                maxLines: 6,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          if (widget.labels.isNotEmpty ||
                              widget.reminder != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: NoteChips(
                                labels: widget.labels,
                                reminder: widget.reminder,
                                dense: true,
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
                  ],
                ),
                if (selectable && (hover || widget.selecting))
                  Positioned(
                    top: 2,
                    left: 2,
                    child: IconButton(
                      tooltip: widget.selected
                          ? 'Deselect note'
                          : 'Select note',
                      visualDensity: VisualDensity.compact,
                      iconSize: 20,
                      onPressed: widget.onSelect,
                      icon: Icon(
                        widget.selected
                            ? Icons.check_circle
                            : Icons.check_circle_outline,
                        color: widget.selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if ((widget.pinned || hover) && !widget.selecting)
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
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final String text;
  final bool done;
  final int indent;
  final ValueChanged<bool> onChanged;
  const _CheckRow({
    required this.text,
    required this.done,
    required this.onChanged,
    this.indent = 0,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: indent * 20.0),
    child: Row(
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
    ),
  );
}
