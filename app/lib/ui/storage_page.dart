import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

import 'stats_widgets.dart';

/// What the messages, posts and files OurNet keeps on this device add up to,
/// where they came from and how fast they grow.
class StoragePage extends StatefulWidget {
  final Node node;
  final String Function(String person) nameOf;

  /// Opens the prompts for the storage limit and warning.
  final Future<void> Function() editLimits;
  const StoragePage({
    super.key,
    required this.node,
    required this.nameOf,
    required this.editLimits,
  });

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  StorageReport? report;
  Object? error;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final r = await StorageReport.build(widget.node.store, person: widget.node.person);
      if (mounted) setState(() => report = r);
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  static const _kindNames = {
    'message': 'Chat messages',
    'message_edit': 'Message edits',
    'message_delete': 'Message deletions',
    'room_post': 'Group posts',
    'room_item': 'Group items',
    'room': 'Groups',
    'room_add': 'Group members added',
    'room_leave': 'Group departures',
    'room_invite': 'Group invitations',
    'room_read': 'Group read marks',
    'post': 'Forum posts',
    'forum': 'Forums',
    'forum_hide': 'Hidden forum posts',
    'note_op': 'Note edits',
    'avatar': 'Pictures',
    'profile': 'Profiles',
    'reaction': 'Reactions',
    'vote': 'Votes',
    'delegate': 'Vote delegations',
    'revoke': 'Revoked devices',
    'device_name': 'Device names',
    'keys': 'Group keys',
    'contact_state': 'Contact choices',
    'read': 'Read marks',
    'inbox': 'Inbox',
  };

  static String kindName(String kind) {
    final known = _kindNames[kind];
    if (known != null) return known;
    final words = kind.replaceAll('_', ' ');
    return words.isEmpty ? 'Other' : words[0].toUpperCase() + words.substring(1);
  }

  static String _date(DateTime? t) {
    if (t == null) return '–';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${t.day} ${months[t.month - 1]} ${t.year}';
  }

  @override
  Widget build(BuildContext context) {
    final r = report;
    final theme = Theme.of(context);
    final colors = StatColors.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Storage', style: theme.textTheme.headlineSmall),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: loading ? null : load,
                  icon: loading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Could not read storage: $error'),
              )
            else if (r == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 64),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              _usage(context, r, colors),
              _composition(context, r, colors),
              _byKind(context, r, colors),
              _byPerson(context, r, colors),
              _growth(context, r, colors),
              _disk(context, r),
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Text(
                  'Measured ${TimeOfDay.fromDateTime(r.at).format(context)}. '
                  'Totals come from counters kept as things are stored; the breakdowns '
                  'are counted when you open or refresh this page.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _usage(BuildContext context, StorageReport r, StatColors colors) {
    final theme = Theme.of(context);
    final fraction = r.limit == 0 ? 0.0 : r.stored / r.limit;
    final full = r.stored >= r.limit;
    final warn = r.stored >= r.warning;
    final tone = full
        ? theme.colorScheme.error
        : warn
        ? colors.upload
        : colors.download;
    return StatSection(
      title: 'In use',
      subtitle: 'What counts towards your limit: messages, posts and files',
      trailing: TextButton(
        onPressed: () async {
          await widget.editLimits();
          if (mounted) await load();
        },
        child: const Text('Change limits'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                sizeText(r.stored),
                style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, color: tone),
              ),
              const SizedBox(width: 8),
              Text('of ${sizeText(r.limit)}', style: theme.textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedBar(
            segments: [
              (value: r.objectBytes.toDouble(), color: colors.series[0]),
              (value: r.fileBytes.toDouble(), color: colors.series[2]),
            ],
            total: r.limit.toDouble(),
            height: 14,
            marks: [r.warning / r.limit],
          ),
          const SizedBox(height: 8),
          Text(
            full
                ? 'The limit is reached: new items from friends are refused. What you write is still saved.'
                : '${percentText(fraction)} of the limit used. Warns at ${sizeText(r.warning)}; '
                      '${sizeText(r.limit - r.stored)} left before friends’ items are refused.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          FigureGrid([
            Figure(value: countText(r.objectCount), label: 'items stored', icon: Icons.article_outlined),
            Figure(value: countText(r.fileChunks), label: 'file chunks', icon: Icons.attach_file),
            Figure(value: sizeText(r.ownBytes), label: 'written by you', icon: Icons.edit_outlined),
            Figure(
              value: sizeText(r.objectBytes - r.ownBytes),
              label: 'from friends',
              icon: Icons.people_outline,
            ),
          ]),
        ],
      ),
    );
  }

  Widget _composition(BuildContext context, StorageReport r, StatColors colors) {
    final parts = <({String label, int bytes, String? note, Color color})>[
      (label: 'Messages, posts and notes', bytes: r.objectBytes, note: '${countText(r.objectCount)} items', color: colors.series[0]),
      (label: 'Files', bytes: r.fileBytes, note: '${countText(r.fileChunks)} chunks', color: colors.series[2]),
      (label: 'Picture previews', bytes: r.previewBytes, note: '${countText(r.previewCount)} previews', color: colors.series[3]),
      (label: 'Delivery receipts', bytes: r.evidenceBytes, note: '${countText(r.evidenceCount)} records', color: colors.series[4]),
      (label: 'Indexes and overhead', bytes: r.overheadBytes, note: null, color: colors.series[5]),
      (label: 'Free space inside the file', bytes: r.freeBytes, note: 'reusable', color: colors.series[7]),
    ];
    final total = parts.fold<int>(0, (s, p) => s + p.bytes);
    return StatSection(
      title: 'What’s in the database',
      subtitle: 'Everything OurNet keeps in its one database file',
      child: Column(
        children: [
          SegmentedBar(
            segments: [for (final p in parts) (value: p.bytes.toDouble(), color: p.color)],
            height: 18,
          ),
          const SizedBox(height: 14),
          for (final p in parts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(child: LegendDot(color: p.color, label: p.label, value: p.note)),
                  Text(
                    '${sizeText(p.bytes)}  ·  ${percentText(total == 0 ? 0 : p.bytes / total)}',
                    style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _byKind(BuildContext context, StorageReport r, StatColors colors) {
    final shown = r.kinds.take(10).toList();
    final rest = r.kinds.skip(10).fold<int>(0, (s, k) => s + k.bytes);
    final peak = shown.isEmpty ? 1 : shown.first.bytes;
    return StatSection(
      title: 'By kind',
      subtitle: 'Which sorts of item take the space',
      child: Column(
        children: [
          for (final (i, k) in shown.indexed)
            BarRow(
              label: kindName(k.id),
              value: sizeText(k.bytes),
              detail: '${countText(k.count)} items'
                  '${k.count == 0 ? '' : ' · ${sizeText(k.bytes / k.count)} each'}',
              fraction: peak == 0 ? 0 : k.bytes / peak,
              color: colors.series[i % colors.series.length],
            ),
          if (rest > 0)
            BarRow(
              label: 'Everything else',
              value: sizeText(rest),
              fraction: peak == 0 ? 0 : rest / peak,
              color: colors.series.last,
            ),
        ],
      ),
    );
  }

  Widget _byPerson(BuildContext context, StorageReport r, StatColors colors) {
    final shown = r.authors.take(8).toList();
    final peak = shown.isEmpty ? 1 : shown.first.bytes;
    return StatSection(
      title: 'By author',
      subtitle: 'Who wrote what is stored here',
      child: Column(
        children: [
          for (final a in shown)
            BarRow(
              label: a.id == widget.node.person ? 'You' : widget.nameOf(a.id),
              value: sizeText(a.bytes),
              detail: '${countText(a.count)} items',
              fraction: peak == 0 ? 0 : a.bytes / peak,
              color: a.id == widget.node.person ? colors.download : colors.series[2],
            ),
          if (r.authors.length > shown.length)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '+ ${r.authors.length - shown.length} more',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  Widget _growth(BuildContext context, StorageReport r, StatColors colors) {
    if (r.months.isEmpty) return const SizedBox.shrink();
    final total = r.months.fold<int>(0, (s, m) => s + m.bytes);
    return StatSection(
      title: 'Added by month',
      subtitle: 'Items by the month they were created, last ${r.months.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StackedBars(
            bars: [
              for (final m in r.months)
                (
                  label: m.id.length >= 7 ? m.id.substring(5) : m.id,
                  a: 0.0,
                  b: m.bytes.toDouble(),
                ),
            ],
            aColor: colors.series[0],
            bColor: colors.series[0],
          ),
          const SizedBox(height: 8),
          Text(
            '${sizeText(total)} in ${r.months.length} months, about ${sizeText(total / r.months.length)} a month.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _disk(BuildContext context, StorageReport r) => StatSection(
    title: 'On disk',
    child: FigureGrid([
      Figure(value: sizeText(r.databaseBytes), label: 'database file', icon: Icons.storage),
      Figure(value: sizeText(r.walBytes), label: 'write-ahead log', icon: Icons.history),
      Figure(value: sizeText(r.freeBytes), label: 'reusable inside file', icon: Icons.recycling),
      Figure(value: _date(r.oldest), label: 'oldest item', icon: Icons.first_page),
      Figure(value: _date(r.newest), label: 'newest item', icon: Icons.last_page),
    ]),
  );
}
