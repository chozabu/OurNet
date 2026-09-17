import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

/// Imports notes from Google Takeout zips (Takeout → Keep). Returns the
/// number of notes imported or given their Keep edit time.
Future<int> importKeepNotes(BuildContext context, Notes notes) async {
  final picked = await FilePicker.pickFiles(
    dialogTitle: 'Choose your Google Takeout zip',
    type: FileType.custom,
    allowedExtensions: const ['zip'],
  );
  final paths = [for (final f in picked) ?f.path];
  if (paths.isEmpty || !context.mounted) return 0;

  // Takeout may split a large export across several zips.
  final streams = [for (final p in paths) InputFileStream(p)];
  try {
    final files = <String, ArchiveFile>{};
    for (final stream in streams) {
      for (final f in ZipDecoder().decodeStream(stream).files) {
        if (f.isFile && f.name.contains('Keep/')) {
          files[f.name.split('/').last] = f;
        }
      }
    }
    final json = <String, List<int>>{
      for (final e in files.entries)
        if (e.key.endsWith('.json'))
          e.key: e.value.readBytes() ?? const <int>[],
    };
    final source = await compute(_parse, json);
    if (source.isEmpty) {
      throw StateError(
        'No Keep notes found. Choose the zip from takeout.google.com with Keep selected.',
      );
    }
    final importer = KeepImport(notes);
    final plan = await importer.plan(source);
    if (!context.mounted || !await _confirm(context, plan)) return 0;
    if (!context.mounted) return 0;

    final done = ValueNotifier(0);
    var cancelled = false;
    final navigator = Navigator.of(context, rootNavigator: true);
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Importing from Keep'),
        content: ValueListenableBuilder(
          valueListenable: done,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$value of ${plan.notes.length} notes'),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: plan.notes.isEmpty ? null : value / plan.notes.length,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => cancelled = true,
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    final KeepResult result;
    try {
      result = await importer.run(
        plan,
        (path) async => files[path.split('/').last]?.readBytes(),
        progress: (value, _) => done.value = value,
        cancelled: () => cancelled,
      );
    } finally {
      navigator.pop();
      await dialog;
      done.dispose();
    }
    if (context.mounted) await _report(context, plan, result, cancelled);
    return result.imported + result.editTimes;
  } finally {
    for (final s in streams) {
      await s.close();
    }
  }
}

List<KeepNote> _parse(Map<String, List<int>> json) => [
  for (final e in json.entries) ?KeepNote.parse(e.key, _decode(e.value)),
];

Object? _decode(List<int> bytes) {
  try {
    return jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return null;
  }
}

Future<bool> _confirm(BuildContext context, KeepPlan plan) async {
  final reasons = <String, int>{};
  for (final (_, reason) in plan.skipped) {
    reasons[reason] = (reasons[reason] ?? 0) + 1;
  }
  final archived = plan.notes.where((n) => n.archived).length;
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Import from Google Keep'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plan.notes.isEmpty
                      ? 'There are no new notes to import.'
                      : '${_count(plan.notes.length, 'note')} will be added'
                            '${archived > 0 ? ', $archived of them to Archive' : ''}.',
                ),
                if (plan.editTimes.isNotEmpty)
                  Text(
                    '${_count(plan.editTimes.length, 'note')} imported earlier will get their Keep edit times.',
                  ),
                if (plan.existing > plan.editTimes.length)
                  Text(
                    '${_count(plan.existing - plan.editTimes.length, 'note')} imported earlier will be left as they are.',
                  ),
                for (final e in reasons.entries)
                  Text('Not imported: ${e.value} · ${e.key}'),
                const SizedBox(height: 12),
                const Text(
                  'People a note was shared with are not added; share it again with OurNet friends.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            if (plan.notes.isNotEmpty || plan.editTimes.isNotEmpty)
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Import'),
              ),
          ],
        ),
      ) ==
      true;
}

Future<void> _report(
  BuildContext context,
  KeepPlan plan,
  KeepResult result,
  bool cancelled,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(cancelled ? 'Import stopped' : 'Import finished'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_count(result.imported, 'note')} imported'
            '${result.editTimes > 0 ? ', and edit times kept for ${_count(result.editTimes, 'earlier note')}' : ''}'
            '${cancelled ? ' of ${plan.notes.length}. Import again to continue.' : '.'}',
          ),
          if (result.problems.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Not imported:'),
            for (final (name, reason) in result.problems)
              Text('• $name: $reason'),
          ],
        ],
      ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Done'),
      ),
    ],
  ),
);

String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
