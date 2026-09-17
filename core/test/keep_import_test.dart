import 'dart:convert';
import 'dart:io';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

Map<String, Object?> keep({
  String title = '',
  String? text = '',
  String? html,
  List<(String, bool)>? items,
  String color = 'DEFAULT',
  bool pinned = false,
  bool archived = false,
  bool trashed = false,
  int created = 1700000000000000,
  List<String> labels = const [],
  List<(String, String)> attachments = const [],
}) => {
  'color': color,
  'isTrashed': trashed,
  'isPinned': pinned,
  'isArchived': archived,
  'title': title,
  'userEditedTimestampUsec': created,
  'createdTimestampUsec': created,
  if (text != null) 'textContent': text,
  if (html != null) 'textContentHtml': html,
  if (items != null)
    'listContent': [
      for (final (t, done) in items)
        {'textHtml': t, 'text': t, 'isChecked': done},
    ],
  if (labels.isNotEmpty)
    'labels': [
      for (final l in labels) {'name': l},
    ],
  if (attachments.isNotEmpty)
    'attachments': [
      for (final (path, mime) in attachments)
        {'filePath': path, 'mimetype': mime},
    ],
};

// Keep's styling on every span, as in a real export.
String span(String text, {int weight = 400, String style = 'normal'}) =>
    '<span style="font-size:7.2pt;font-weight:$weight;font-style:$style;'
    'text-decoration:none;white-space:pre-wrap;">$text</span>';

List<int> amr(int frames) => [
  ...ascii.encode('#!AMR\n'),
  for (var i = 0; i < frames; i++) ...[0x3c, ...List.filled(31, 0)],
];

void main() {
  group('parsing', () {
    test('plain HTML keeps the plain text, without markup', () {
      final note = KeepNote.parse(
        'a.json',
        keep(
          text: 'one * two\n three',
          html:
              '<p dir="ltr">${span('one * two')}</p><br><p>${span('&nbsp;three')}</p>',
        ),
      )!;
      expect(note.format, isNull);
      expect(note.text, 'one * two\n three');
    });

    test('bold, italic and headings become markup', () {
      expect(
        keepMarkup(
          '<h1>${span('Title')}</h1>'
          '<p>${span('a ')}${span('bold ', weight: 700)}'
          '${span('slanted', style: 'italic')}${span(' &amp; &lt;x&gt;')}</p>'
          '<h2>${span('Sub')}</h2><p>${span('end')}</p>',
        ),
        '# Title\na **bold** *slanted* & <x>\n## Sub\nend',
      );
      expect(keepMarkup('<p>${span('nothing')}</p>'), isNull);
    });

    test('fields map to OurNet names and links stay in the text', () {
      final note = KeepNote.parse('b.json', {
        ...keep(
          title: 'T',
          text: 'see',
          color: 'CERULEAN',
          archived: true,
          created: 1377397177550000,
          labels: ['Work'],
          attachments: [('x.3gp', 'audio/3gp')],
        ),
        'annotations': [
          {'url': 'https://example.com/', 'title': 'Ex', 'source': 'WEBLINK'},
        ],
      })!;
      expect(note.color, 'storm');
      expect(note.archived, true);
      expect(note.created, 1377397177550);
      expect(note.labels, ['Work']);
      expect(note.attachments.single.path, 'x.3gp');
      expect(note.text, 'see\nhttps://example.com/');
      expect(KeepNote.parse('c.json', keep(color: 'DEFAULT'))!.color, isNull);
      expect(KeepNote.parse('Labels.json', {'x': 1}), isNull);
      // A link-only note has neither text nor a list.
      final link = KeepNote.parse('d.json', {
        ...keep(text: null, title: 'Link'),
        'annotations': [
          {'url': 'https://example.com/'},
        ],
      })!;
      expect(link.text, 'https://example.com/');
    });

    test('AMR duration counts 20 ms frames', () {
      expect(amrDuration(amr(50)), 1000);
      expect(amrDuration([0, 0, 0, 0x18, ...ascii.encode('ftyp3gp4')]), isNull);
    });
  });

  group('importing', () {
    late Node node;
    late Notes notes;
    setUp(() async {
      node = Node(await LocalIdentity.create(), Store());
      notes = Notes(node);
    });
    tearDown(() => node.close());

    test('imports lists, state, labels and attachments once', () async {
      final source = [
        KeepNote.parse(
          'list.json',
          keep(
            title: 'Shopping',
            text: null,
            items: [('milk', true), ('eggs', false)],
            color: 'GREEN',
            pinned: true,
            labels: ['Home', 'home'],
            created: 1600000000000000,
          ),
        )!,
        KeepNote.parse(
          'voice.json',
          keep(
            text: 'transcript',
            archived: true,
            labels: ['Home'],
            attachments: [
              ('rec.3gp', 'audio/3gp'),
              ('pic.jpg', 'image/jpeg'),
              ('gone.png', 'image/png'),
            ],
          ),
        )!,
        KeepNote.parse('trash.json', keep(text: 'old', trashed: true))!,
      ];
      final files = {'rec.3gp': amr(10), 'pic.jpg': utf8.encode('jpeg')};
      final plan = await KeepImport(notes).plan(source);
      expect(plan.notes.map((n) => n.name), ['list.json', 'voice.json']);
      expect(plan.skipped.single.$1.name, 'trash.json');
      final result = await KeepImport(notes).run(plan, (p) async => files[p]);
      expect(result.imported, 2);
      expect(result.problems.single.$1, 'gone.png');

      final ids = [for (final s in await notes.summaries()) s.data['entry']];
      final list = (await notes.get(
        ids.firstWhere((id) => id.contains(source[0].stableId)),
      ))!;
      expect(list.rawTitle, 'Shopping');
      expect([for (final c in list.checks) list.done(c)], [true, false]);
      expect(list.color, 'mint');
      expect(list.created, 1600000000000);
      expect(notes.pinned(list.id), true);
      expect(notes.state.labels.values, ['Home']);

      final voice = (await notes.get(
        ids.firstWhere((id) => id.contains(source[1].stableId)),
      ))!;
      expect(notes.state.archived(voice.id), true);
      expect(notes.state.labelsOf(voice.id), notes.state.labelsOf(list.id));
      expect(
        [for (final f in voice.files) voice.fileMeta(f)['kind']],
        ['audio', 'image'],
      );
      final audio = voice.fileMeta(voice.files.first);
      expect(audio['mime'], 'audio/amr');
      expect(audio['duration'], 200);
      expect(voice.file(voice.files.first)!.data['name'], 'rec.amr');

      final again = await KeepImport(notes).plan(source);
      expect(again.notes, isEmpty);
      expect(again.existing, 2);
    });

    test('long titles move into the text', () async {
      final title = 'word ' * 30;
      final k = KeepNote.parse('t.json', keep(title: title, text: 'body'))!;
      await KeepImport(
        notes,
      ).run(await KeepImport(notes).plan([k]), (_) async => null);
      final note = (await notes.get(
        (await notes.summaries()).single.data['entry'],
      ))!;
      expect(note.rawTitle.length, 100);
      expect(note.text, '${title.trim()}\n\nbody');
    });

    test('imports oldest first, so the newest note is on top', () async {
      final source = [
        for (final i in [3, 1, 2])
          KeepNote.parse('$i.json', keep(text: '$i', created: i * 1000000))!,
      ];
      final plan = await KeepImport(notes).plan(source);
      expect(plan.notes.map((n) => n.name), ['1.json', '2.json', '3.json']);
    });

    test('Keep edit times are kept until the note is edited', () async {
      var clock = 1800000000000;
      final timed = Node(
        await LocalIdentity.create(),
        Store(),
        clock: () => clock,
      );
      addTearDown(timed.close);
      final notes = Notes(timed);
      final importer = KeepImport(notes);
      Map<String, Object?> edited(String text, int usec) => {
        ...keep(
          text: text,
          created: 1600000000000000 + text.codeUnitAt(0) * 1000,
        ),
        'userEditedTimestampUsec': usec,
      };
      final fresh = KeepNote.parse('a.json', edited('a', 1700000000000000))!;
      final undated = KeepNote.parse('b.json', edited('b', 0))!;
      expect(undated.edited, undated.created);
      // Imported before edit times were kept: one untouched, one edited.
      final older = KeepNote.parse('c.json', edited('c', 1650000000000000))!;
      final changed = KeepNote.parse('d.json', edited('d', 1660000000000000))!;
      for (final k in [older, changed]) {
        await notes.create(
          text: k.text,
          created: k.created,
          stableId: k.stableId,
        );
      }
      clock += 60 * 60 * 1000;
      final d = (await notes.get('room2:${timed.person}:${changed.stableId}'))!;
      await notes.set(d, 'text', 'd, later');

      clock += 1000;
      final plan = await importer.plan([fresh, undated, older, changed]);
      expect(plan.notes, [fresh, undated]);
      expect(plan.editTimes, [older]);
      final result = await importer.run(plan, (_) async => null);
      expect((result.imported, result.editTimes), (2, 1));

      Future<int> updated(KeepNote k) async =>
          (await notes.get('room2:${timed.person}:${k.stableId}'))!.updated;
      expect(await updated(fresh), 1700000000000);
      expect(await updated(undated), undated.created);
      expect(await updated(older), 1650000000000);
      expect(await updated(changed), 1800000000000 + 60 * 60 * 1000);
      final summary = (await notes.summaries()).firstWhere(
        (s) => (s.data['entry'] as String).endsWith(fresh.stableId),
      );
      expect(summary.data['updated'], 1700000000000);

      // Editing after the import counts, and importing again changes nothing.
      clock += 5000;
      final a = (await notes.get('room2:${timed.person}:${fresh.stableId}'))!;
      await notes.set(a, 'text', 'a, edited');
      expect(await updated(fresh), clock);
      final again = await importer.plan([fresh, undated, older, changed]);
      expect(again.notes, isEmpty);
      expect(again.editTimes, isEmpty);
      expect(again.existing, 4);
    });

    final export = Platform.environment['OURNET_KEEP_EXPORT'];
    test(
      'a real Takeout export plans and imports',
      () async {
        final folder = Directory(export!);
        final source = [
          for (final f in folder.listSync().whereType<File>())
            if (f.path.endsWith('.json'))
              KeepNote.parse(
                f.uri.pathSegments.last,
                jsonDecode(f.readAsStringSync()),
              ),
        ].nonNulls.toList();
        final plan = await KeepImport(notes).plan(source);
        final result = await KeepImport(notes).run(plan, (p) async {
          final f = File('${folder.path}/$p');
          return f.existsSync() ? f.readAsBytesSync() : null;
        });
        print(
          'parsed ${source.length}, imported ${result.imported}, '
          'skipped ${plan.skipped.length}, problems ${result.problems}',
        );
        expect(result.imported, plan.notes.length);
        expect(result.problems, isEmpty);
      },
      skip: export == null ? 'Set OURNET_KEEP_EXPORT to a Keep folder' : false,
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}
