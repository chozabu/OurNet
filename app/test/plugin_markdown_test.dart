import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:ournet/ui/plugin_markdown.dart';

Future<void> waitFor(WidgetTester tester, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Markdown did not finish rendering');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Widget page(Widget child) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

void main() {
  test('GFM and README HTML retain semantics without active HTML', () {
    final doc = html.parseFragment(
      markdownHtml('''
# Heading

| Name | Value |
| :--- | ---: |
| **one** | ~~two~~ |

- [x] complete
- [ ] pending

> A quote with `inline code`.

```dart
print('<hello>');
```

<table><tr><td width="50%"><img src="docs/pic.png" alt="Picture"></td></tr></table>
<details><summary>Details</summary>More information</details>
<script>bad()</script><iframe src="file:///secret">bad</iframe>
<span style="background-image: url(file:///secret)" onclick="bad()">safe</span>

[Reference][doc] and [[Wiki page]].

[doc]: docs/guide.md
'''),
    );
    expect(doc.querySelectorAll('table'), hasLength(2));
    expect(doc.querySelector('h1')!.id, 'heading');
    expect(doc.querySelector('del')!.text, 'two');
    expect(doc.querySelector('pre code')!.classes, contains('language-dart'));
    expect(doc.querySelector('pre')!.text, "print('<hello>');\n");
    expect(doc.querySelector('blockquote code')!.text, 'inline code');
    expect(doc.querySelectorAll('input[type=checkbox]'), hasLength(2));
    expect(doc.querySelector('img')!.attributes['src'], 'docs/pic.png');
    expect(doc.querySelector('td[width]')!.attributes['width'], '50%');
    expect(doc.querySelector('details summary')!.text, 'Details');
    expect(doc.querySelectorAll('script,iframe,[style],[onclick]'), isEmpty);
    expect(doc.querySelector('a[href="docs/guide.md"]')!.text, 'Reference');
    expect(doc.querySelector('a[href^="ournet-wiki:"]')!.text, 'Wiki page');
  });

  test('repository URLs resolve from the document directory', () {
    expect(
      markdownRepositoryPath('docs/design', '../guide.md#part'),
      'docs/guide.md',
    );
    expect(markdownRepositoryPath('docs', '/README.md'), 'README.md');
    expect(markdownRepositoryPath('docs', 'a%20b.png?raw=1'), 'docs/a b.png');
    expect(
      markdownRepositoryPath('', 'docs/screenshots/notes.png'),
      'docs/screenshots/notes.png',
    );
    expect(
      markdownRepositoryPath('docs', 'https://example.com/pic.png'),
      isNull,
    );
    expect(markdownRepositoryPath('docs', '//example.com/pic.png'), isNull);
    expect(markdownRepositoryPath('docs', 'file:///secret'), isNull);
    expect(markdownRepositoryPath('', '%2e%2e/secret'), isNull);
    expect(markdownRepositoryPath('', 'folder%2Fsecret'), isNull);
  });

  testWidgets('tables, code copy, task lists and repository/wiki links work', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final links = <String>[];
    await tester.pumpWidget(
      page(
        PluginMarkdown(
          text: '''
# Features

[Guide](../guide.md) and [[Wiki page]]

| Name | Value |
| --- | --- |
| Cell | **Strong** |

- [x] Done
- [ ] Waiting

```dart
print('hello');
```
''',
          repository: 'demo',
          commit: 'abc',
          directory: 'docs/nested',
          onLink: links.add,
        ),
      ),
    );
    await waitFor(
      tester,
      () => find.byTooltip('Copy code').evaluate().isNotEmpty,
    );
    expect(find.text('Cell', findRichText: true), findsOneWidget);
    expect(find.byIcon(Icons.check_box), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
    // Paragraphs fill the width, so tap the link text itself.
    await tester.tapOnText(find.textRange.ofSubstring('Guide'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tapOnText(find.textRange.ofSubstring('Wiki page'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(links, ['docs/guide.md', 'Wiki page']);
    await tester.ensureVisible(find.byTooltip('Copy code'));
    await tester.tap(find.byTooltip('Copy code'));
    await tester.pump();
    expect(copied, "print('hello');\n");
    expect(tester.takeException(), isNull);
  });

  for (final width in [1100.0, 390.0]) {
    testWidgets('the actual OurNet README renders at $width pixels', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final source = File('../README.md').readAsStringSync();
      final loaded = <String>[];
      final shot = GlobalKey();
      await tester.pumpWidget(
        page(
          RepaintBoundary(
            key: shot,
            child: PluginMarkdown(
              text: source,
              repository: 'ournet',
              commit: 'fixed-commit',
              repositoryFile: (repo, commit, path) async {
                expect(repo, 'ournet');
                expect(commit, 'fixed-commit');
                loaded.add(path);
                return File('../$path').readAsBytes();
              },
            ),
          ),
        ),
      );
      await waitFor(
        tester,
        () =>
            loaded.length == 7 &&
            tester
                    .renderObjectList<RenderImage>(find.byType(RawImage))
                    .where((r) => r.image != null)
                    .length ==
                7,
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      expect(
        loaded,
        containsAll([
          'docs/screenshots/notes.png',
          'docs/screenshots/chat.png',
          'docs/screenshots/forums.png',
          'docs/screenshots/calendar.png',
          'docs/screenshots/notes-phone.png',
          'docs/screenshots/plugins.png',
          'docs/screenshots/blast-garden.png',
        ]),
      );
      expect(find.text('What it does', findRichText: true), findsOneWidget);
      expect(find.text('Plugins', findRichText: true), findsOneWidget);
      expect(find.text('powershell'), findsOneWidget);
      expect(find.textContaining('<table>', findRichText: true), findsNothing);
      expect(tester.takeException(), isNull);
      const shots = String.fromEnvironment('MARKDOWN_SHOTS');
      if (shots.isNotEmpty) {
        // Image encoding is real async work, which fake time never finishes.
        await tester.runAsync(() async {
          final image =
              await (shot.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await Directory(shots).create(recursive: true);
          await File(
            '$shots/readme-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
    });
  }

  testWidgets('missing images retry and unsafe resources never load', (
    tester,
  ) async {
    final requests = <String>[];
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aDSkAAAAASUVORK5CYII=',
    );
    var failFirst = true;
    await tester.pumpWidget(
      page(
        PluginMarkdown(
          text:
              '![Local](pic.png)\n\n![Private](file:///secret)\n\n<img src="asset:///secret">',
          repository: 'demo',
          commit: 'one',
          repositoryFile: (_, _, path) async {
            requests.add(path);
            if (failFirst) {
              failFirst = false;
              throw StateError('Not local yet');
            }
            return Uint8List.fromList(png);
          },
        ),
      ),
    );
    await waitFor(
      tester,
      () => find.text('Local — retry image').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Local — retry image'));
    await waitFor(tester, () => find.byType(Image).evaluate().isNotEmpty);
    expect(requests, ['pic.png', 'pic.png']);
    expect(tester.takeException(), isNull);
  });
}
