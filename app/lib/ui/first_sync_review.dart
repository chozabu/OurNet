part of 'app.dart';

/// Shows what connecting a folder to a nonempty drive folder would do and
/// lets the person choose which copies to keep, for everything, a folder or
/// a file. Pops the decisions to connect with, or null to cancel.
class FirstSyncReview extends StatefulWidget {
  final FirstSyncPlan plan;
  final String name;
  const FirstSyncReview({super.key, required this.plan, required this.name});

  @override
  State<FirstSyncReview> createState() => _FirstSyncReviewState();
}

class _Row {
  final String path;
  final int depth;

  /// Null for a folder shown only to hold the rows below it.
  final FirstSyncItem? item;
  final bool folder;
  _Row(this.path, this.item, this.folder) : depth = path.split('/').length - 1;
  String get name => path.split('/').last;
}

const _labels = {
  FirstSyncChoice.both: 'Keep both',
  FirstSyncChoice.here: 'This device wins',
  FirstSyncChoice.drive: 'Drive wins',
};

const _kinds = {
  FirstSyncKind.identical: 'Same on both sides',
  FirstSyncKind.onlyHere: 'Only on this device',
  FirstSyncKind.onlyDrive: 'Only in the drive',
  FirstSyncKind.differs: 'Different on each side',
  FirstSyncKind.clash: 'File on one side, folder on the other',
  FirstSyncKind.staleHere: 'Older copy here; the drive has a newer one',
  FirstSyncKind.deletedElsewhere: 'Deleted from the drive on another device',
  FirstSyncKind.driveConflict: 'Unresolved conflict in the drive',
};

String _when(DateTime? t) {
  if (t == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  final l = t.toLocal();
  return ' · ${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

class _FirstSyncReviewState extends State<FirstSyncReview> {
  var preset = FirstSyncChoice.both;
  var suggestions = true;
  final overrides = <String, FirstSyncChoice>{};
  late final List<_Row> rows;
  late Map<String, FirstSyncChoice> choices;

  @override
  void initState() {
    super.initState();
    // Rows are worked out once: everything that needs attention, with the
    // folders above it so a choice can cover a whole folder.
    final byPath = {for (final i in widget.plan.items) i.path: i};
    final shown = <String>{};
    for (final item in widget.plan.items) {
      if (item.kind == FirstSyncKind.identical) continue;
      var path = item.path;
      shown.add(path);
      while (path.contains('/')) {
        path = path.substring(0, path.lastIndexOf('/'));
        if (!shown.add(path)) break;
      }
    }
    final ordered = shown.toList()
      ..sort(
        (a, b) =>
            a.split('/').join('\u0000').compareTo(b.split('/').join('\u0000')),
      );
    rows = [
      for (final path in ordered)
        _Row(
          path,
          byPath[path]?.kind == FirstSyncKind.identical ? null : byPath[path],
          byPath[path]?.directory ?? true,
        ),
    ];
    _resolve();
  }

  // What each row shows, worked out once per change rather than per row: a
  // file its choice, a folder the one everything in it shares (null when
  // mixed).
  final shown = <String, FirstSyncChoice?>{};
  void _resolve() {
    choices = widget.plan.resolve(preset, overrides, suggestions: suggestions);
    shown.clear();
    void add(String path, FirstSyncChoice choice) {
      if (!shown.containsKey(path)) {
        shown[path] = choice;
      } else if (shown[path] != choice) {
        shown[path] = null;
      }
    }

    for (final row in rows) {
      final item = row.item;
      if (item == null) continue;
      final choice = choices[row.path]!;
      var path = row.path;
      add(path, choice);
      while (path.contains('/')) {
        path = path.substring(0, path.lastIndexOf('/'));
        add(path, choice);
      }
    }
  }

  void _choose(_Row row, FirstSyncChoice choice) => setState(() {
    overrides.removeWhere((path, _) => path.startsWith('${row.path}/'));
    overrides[row.path] = choice;
    _resolve();
  });

  void _preset(FirstSyncChoice choice) => setState(() {
    preset = choice;
    suggestions = false;
    overrides.clear();
    _resolve();
  });

  Future<void> _apply() async {
    final plan = widget.plan;
    final removed = [
      for (final item in plan.items)
        if (item.removes(choices[item.path] ?? FirstSyncChoice.both)) item,
    ];
    final replaced = [
      for (final item in plan.items)
        if (choices[item.path] == FirstSyncChoice.drive &&
            !item.removes(FirstSyncChoice.drive) &&
            item.local != null)
          item,
    ];
    if (removed.isNotEmpty || replaced.isNotEmpty) {
      String list(List<FirstSyncItem> items) => [
        for (final i in items.take(200))
          '• ${i.path} — ${i.effect(choices[i.path]!)}',
        if (items.length > 200) '…and ${items.length - 200} more',
      ].join('\n');
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Move or delete these?'),
          content: SingleChildScrollView(
            child: Text(
              [
                if (removed.isNotEmpty)
                  'Moved aside from this folder (kept in a "not synced" '
                      'folder) or deleted from the drive (restorable from '
                      'drive history):\n${list(removed)}',
                if (replaced.isNotEmpty)
                  'Replaced here by the drive copy if they differ (this '
                      "device's copy is kept in drive history):\n"
                      '${list(replaced)}',
              ].join('\n\n'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Connect folder'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    Navigator.pop<Map<String, Json>>(context, plan.decisions(choices));
  }

  Widget _row(BuildContext context, _Row row) {
    final item = row.item;
    final current = shown[row.path];
    final offered = item == null || row.folder
        ? FirstSyncChoice.values
        : item.choices;
    final theme = Theme.of(context);
    final details = item == null
        ? 'Folder'
        : [
            _kinds[item.kind]!,
            if (item.local != null && !item.local!.directory)
              'Here: ${bytesText(item.local!.size)}${_when(item.local!.modified)}',
            if (item.drive != null &&
                !item.drive!.isFolder &&
                item.kind != FirstSyncKind.deletedElsewhere)
              'Drive: ${bytesText(item.driveSize ?? 0)}${_when(item.driveTime)}',
            if (current != null && !row.folder) item.effect(current),
          ].join('\n');
    return Padding(
      padding: EdgeInsets.only(left: 12.0 + 16 * row.depth.clamp(0, 8)),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.only(right: 8),
        leading: Icon(
          row.folder ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
        ),
        title: Text(row.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(details),
        trailing: offered.length < 2
            ? null
            : PopupMenuButton<FirstSyncChoice>(
                tooltip: row.folder
                    ? 'Choose for everything in ${row.name}'
                    : 'Choose for ${row.name}',
                onSelected: (choice) => _choose(row, choice),
                itemBuilder: (context) => [
                  for (final choice in offered)
                    CheckedPopupMenuItem(
                      value: choice,
                      checked: choice == current,
                      child: Text(_labels[choice]!),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    current == null ? 'Mixed' : _labels[current]!,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final counts = [
      for (final e in plan.counts.entries)
        if (e.value > 0) '${e.value} ${_kinds[e.key]!.toLowerCase()}',
    ];
    return Scaffold(
      appBar: AppBar(title: Text('Connect ${widget.name}')),
      body: ListView.builder(
        itemCount: rows.length + 1,
        itemBuilder: (context, i) {
          if (i > 0) return _row(context, rows[i - 1]);
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This folder and the drive folder both have files. Choose '
                  'which copies to keep where they differ. Nothing is lost: '
                  'a losing copy stays in drive history or is moved to a '
                  '"not synced" folder.',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final c in counts) Chip(label: Text(c))],
                ),
                for (final problem in plan.problems)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      problem,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                // Chips wrap on a phone, where three segments would not fit.
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in FirstSyncChoice.values)
                      ChoiceChip(
                        label: Text(_labels[c]!),
                        selected:
                            !suggestions && overrides.isEmpty && preset == c,
                        onSelected: (_) => _preset(c),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  suggestions
                      ? 'Suggested: keep both, except older copies and files '
                            'deleted on another device, where the drive wins.'
                      : overrides.isNotEmpty
                      ? 'Your choices for some files and folders'
                      : 'Choose per folder or file below',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _apply,
                child: const Text('Connect folder'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
