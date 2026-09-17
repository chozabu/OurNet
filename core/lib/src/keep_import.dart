import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'notes.dart';

final _nbsp = String.fromCharCode(0xa0);

/// One note from a Google Takeout Keep export (`Takeout/Keep/<name>.json`).
/// See NOTES_KEEP.md for how each field maps to a note.
class KeepNote {
  final String name, title, text;

  /// 'markup' when the Keep note used formatting, else null.
  final String? format;
  final List<({String text, bool done})> items;
  final String? color;
  final bool pinned, archived, trashed;

  /// Original creation time in milliseconds.
  final int created;
  final List<String> labels;
  final List<({String path, String mime})> attachments;

  KeepNote({
    required this.name,
    this.title = '',
    this.text = '',
    this.format,
    this.items = const [],
    this.color,
    this.pinned = false,
    this.archived = false,
    this.trashed = false,
    this.created = 0,
    this.labels = const [],
    this.attachments = const [],
  });

  /// Keep's palette names; OurNet uses the names Keep shows.
  static const colors = {
    'RED': 'coral',
    'ORANGE': 'peach',
    'YELLOW': 'sand',
    'GREEN': 'mint',
    'TEAL': 'sage',
    'BLUE': 'fog',
    'CERULEAN': 'storm',
    'PURPLE': 'dusk',
    'PINK': 'blossom',
    'BROWN': 'clay',
    'GRAY': 'chalk',
  };

  /// Parses one Takeout note; returns null for JSON that is not a Keep note.
  static KeepNote? parse(String name, Object? json) {
    if (json is! Map || json['createdTimestampUsec'] is! int) return null;
    String str(Object? v) => v is String ? v.replaceAll(_nbsp, ' ') : '';
    var text = str(json['textContent']);
    String? format;
    final html = json['textContentHtml'];
    if (html is String) {
      final markup = keepMarkup(html);
      if (markup != null) {
        text = markup;
        format = 'markup';
      }
    }
    // Web links Keep shows as cards stay findable in the text.
    for (final a in json['annotations'] is List ? json['annotations'] : []) {
      final url = a is Map ? str(a['url']) : '';
      if (url.isNotEmpty && !text.contains(url)) {
        text = text.isEmpty ? url : '$text\n$url';
      }
    }
    return KeepNote(
      name: name,
      title: str(json['title']),
      text: text,
      format: format,
      items: [
        for (final i in json['listContent'] is List ? json['listContent'] : [])
          if (i is Map) (text: str(i['text']), done: i['isChecked'] == true),
      ],
      color: colors[json['color']],
      pinned: json['isPinned'] == true,
      archived: json['isArchived'] == true,
      trashed: json['isTrashed'] == true,
      created: (json['createdTimestampUsec'] as int) ~/ 1000,
      labels: [
        for (final l in json['labels'] is List ? json['labels'] : [])
          if (l is Map && str(l['name']).trim().isNotEmpty) str(l['name']),
      ],
      attachments: [
        for (final a in json['attachments'] is List ? json['attachments'] : [])
          if (a is Map && str(a['filePath']).isNotEmpty)
            (path: str(a['filePath']), mime: str(a['mimetype'])),
      ],
    );
  }

  /// Stable across repeated exports of the same Keep note, so importing again
  /// finds the earlier copy instead of duplicating it.
  String get stableId =>
      'keep-${sha256.convert(utf8.encode('$created\n$title')).toString().substring(0, 32)}';
}

/// Converts Keep's `textContentHtml` to `NoteMarkup`, or returns null when
/// the note has no bold, italic, underline or headings (plain text is safer:
/// literal `*` in it would otherwise read as formatting).
String? keepMarkup(String html) {
  final out = StringBuffer();
  var formatted = false;
  // Open inline markers, innermost last, per open span.
  final spans = <List<String>>[];
  final tag = RegExp(r'<(/?)(\w+)([^>]*)>');
  var cursor = 0;
  void text(String raw) {
    if (raw.isEmpty) return;
    final value = _unescape(raw);
    final markers = spans.expand((m) => m).toList();
    if (markers.isEmpty || value.trim().isEmpty) {
      out.write(value);
      return;
    }
    // Markers must hug non-space text to be recognised.
    final lead = RegExp(r'^\s*').stringMatch(value)!;
    final trail = RegExp(r'\s*$').stringMatch(value)!;
    final core = value.substring(lead.length, value.length - trail.length);
    out
      ..write(lead)
      ..write(markers.join())
      ..write(core)
      ..write(markers.reversed.join())
      ..write(trail);
    formatted = true;
  }

  for (final m in tag.allMatches(html)) {
    text(html.substring(cursor, m.start));
    cursor = m.end;
    final closing = m.group(1) == '/';
    final name = m.group(2)!.toLowerCase();
    final attrs = m.group(3)!;
    switch (name) {
      case 'br':
        out.write('\n');
      case 'p' || 'div' || 'li' when closing:
        out.write('\n');
      case 'h1' || 'h2' || 'h3' when !closing:
        out.write(name == 'h1' ? '# ' : '## ');
        formatted = true;
      case 'h1' || 'h2' || 'h3':
        out.write('\n');
      case 'span' || 'b' || 'strong' || 'i' || 'em' || 'u' when closing:
        if (spans.isNotEmpty) spans.removeLast();
      case 'span' || 'b' || 'strong' || 'i' || 'em' || 'u':
        final style = attrs.toLowerCase();
        spans.add([
          if (name == 'b' ||
              name == 'strong' ||
              RegExp(r'font-weight:\s*(bold|[6-9]00)').hasMatch(style))
            '**',
          if (name == 'i' ||
              name == 'em' ||
              style.contains('font-style:italic'))
            '*',
          if (name == 'u' ||
              RegExp(r'text-decoration:[^;"]*underline').hasMatch(style))
            '__',
        ]);
    }
  }
  text(html.substring(cursor));
  if (!formatted) return null;
  final result = out.toString();
  return result.endsWith('\n')
      ? result.substring(0, result.length - 1)
      : result;
}

String _unescape(String s) => s
    .replaceAllMapped(
      RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos|nbsp);'),
      (m) {
        final e = m.group(1)!;
        if (e.startsWith('#x'))
          return String.fromCharCode(int.parse(e.substring(2), radix: 16));
        if (e.startsWith('#'))
          return String.fromCharCode(int.parse(e.substring(1)));
        return const {
          'amp': '&',
          'lt': '<',
          'gt': '>',
          'quot': '"',
          'apos': "'",
          'nbsp': ' ',
        }[e]!;
      },
    )
    .replaceAll(_nbsp, ' ');

/// Milliseconds of an AMR-NB file (Keep's `.3gp` recordings are raw AMR), or
/// null when [bytes] is not AMR-NB.
int? amrDuration(List<int> bytes) {
  const header = '#!AMR\n';
  if (bytes.length < header.length ||
      String.fromCharCodes(bytes.take(header.length)) != header) {
    return null;
  }
  // Speech bytes per frame type; each frame is 20 ms plus a one-byte header.
  const sizes = [12, 13, 15, 17, 19, 20, 26, 31, 5, 0, 0, 0, 0, 0, 0, 0];
  var frames = 0;
  for (var i = header.length; i < bytes.length; frames++) {
    i += 1 + sizes[(bytes[i] >> 3) & 0x0f];
  }
  return frames * 20;
}

/// What an import would do, so the person can confirm first.
class KeepPlan {
  /// In import order: oldest first, so the newest ends up on top.
  final List<KeepNote> notes;
  final int existing;
  final List<(KeepNote, String)> skipped;
  KeepPlan(this.notes, this.existing, this.skipped);
}

class KeepResult {
  int imported = 0;

  /// Note or attachment names with the reason each was not imported.
  final problems = <(String, String)>[];
}

/// Imports Google Takeout Keep notes as this person's notes.
class KeepImport {
  final Notes notes;
  KeepImport(this.notes);

  static const _audio = {'audio/3gp', 'audio/3gpp', 'audio/amr'};

  String _id(KeepNote note) => 'room2:${notes.node.person}:${note.stableId}';

  /// Chooses what fits: trashed notes are left out, then active notes are
  /// preferred over archived ones, newest first, within [Notes.maxNotes].
  Future<KeepPlan> plan(Iterable<KeepNote> source) async {
    final skipped = <(KeepNote, String)>[];
    final candidates = <KeepNote>[];
    var existing = 0;
    for (final note in source) {
      final reason = note.trashed
          ? 'In Keep’s trash'
          : note.text.length > 16384 ||
                note.items.any((i) => i.text.length > 16384)
          ? 'Text is longer than 16,384 characters'
          : note.items.length > Notes.maxChecks
          ? 'More than ${Notes.maxChecks} list items'
          : null;
      if (reason != null) {
        skipped.add((note, reason));
      } else if (await notes.get(_id(note), includeUnavailable: true) != null) {
        existing++;
      } else {
        candidates.add(note);
      }
    }
    candidates.sort((a, b) {
      if (a.archived != b.archived) return a.archived ? 1 : -1;
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.created.compareTo(a.created);
    });
    final space = (Notes.maxNotes - (await notes.summaries()).length).clamp(
      0,
      Notes.maxNotes,
    );
    for (final note in candidates.skip(space)) {
      skipped.add((note, 'No room: up to ${Notes.maxNotes} notes'));
    }
    final chosen = candidates.take(space).toList()
      ..sort((a, b) => a.created.compareTo(b.created));
    return KeepPlan(chosen, existing, skipped);
  }

  /// Imports [plan]. [read] returns an attachment's bytes by its Takeout
  /// path, or null when missing. Stops before the next note once [cancelled].
  Future<KeepResult> run(
    KeepPlan plan,
    Future<List<int>?> Function(String path) read, {
    void Function(int done, int total)? progress,
    bool Function()? cancelled,
  }) async {
    final result = KeepResult();
    final labels = <String, String>{};
    for (final (i, k) in plan.notes.indexed) {
      if (cancelled?.call() ?? false) break;
      progress?.call(i, plan.notes.length);
      try {
        await _import(k, read, labels, result);
        result.imported++;
      } catch (e) {
        result.problems.add((_label(k), '$e'));
      }
    }
    progress?.call(plan.notes.length, plan.notes.length);
    return result;
  }

  static String _label(KeepNote k) => k.title.trim().isNotEmpty
      ? k.title.trim()
      : k.text.trim().isNotEmpty
      ? k.text.trim().split('\n').first
      : k.name;

  Future<void> _import(
    KeepNote k,
    Future<List<int>?> Function(String path) read,
    Map<String, String> labels,
    KeepResult result,
  ) async {
    var title = k.title.trim(), text = k.text;
    if (title.length > 100) {
      // Keep the whole title readable at the top of the text.
      text = text.isEmpty ? title : '$title\n\n$text';
      title = '${title.substring(0, 99)}…';
    }
    var note = await notes.create(
      title: title,
      text: text.length > 16384 ? k.text : text,
      items: [for (final i in k.items) i.text],
      color: k.color,
      format: k.format,
      created: k.created,
      stableId: k.stableId,
    );
    final checks = note.checks;
    final done = [
      for (final (i, item) in k.items.indexed)
        if (item.done && i < checks.length)
          (field: 'check:${checks[i]}:done', value: true, parents: <String>[]),
    ];
    if (done.isNotEmpty) await notes.apply(note.id, note.epoch, done);

    for (final a in k.attachments) {
      final name = a.path.split('/').last;
      if (note.files.length >= Notes.maxFiles) {
        result.problems.add((
          name,
          'A note holds up to ${Notes.maxFiles} attachments',
        ));
        continue;
      }
      final bytes = await read(a.path);
      if (bytes == null) {
        result.problems.add((name, 'Missing from the export'));
        continue;
      }
      try {
        if (a.mime.startsWith('image/')) {
          await notes.attachImage(note, Stream.value(bytes), name);
        } else if (_audio.contains(a.mime)) {
          final amr = amrDuration(bytes);
          await notes.attachAudio(
            note,
            Stream.value(bytes),
            name: amr == null
                ? name
                : '${name.replaceFirst(RegExp(r'\.\w+$'), '')}.amr',
            mime: amr == null ? 'audio/3gpp' : 'audio/amr',
            duration: amr ?? 0,
          );
        } else {
          result.problems.add((name, 'Unsupported attachment (${a.mime})'));
          continue;
        }
      } catch (e) {
        result.problems.add((name, '$e'));
      }
      note = (await notes.get(note.id))!;
    }

    for (final label in k.labels) {
      final id = labels[label.toLowerCase()] ??= await notes.state.createLabel(
        label.trim(),
      );
      await notes.state.label([note.id], id, true);
    }
    if (k.archived) {
      await notes.state.archive([note.id], true);
    } else if (k.pinned) {
      await notes.pin(note.id, true);
    }
  }
}
