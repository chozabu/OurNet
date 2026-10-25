import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/git_code_browser.dart';
import 'package:ournet/ui/git_network.dart';

Future<void> until(WidgetTester tester, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Browser did not finish loading');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  test('syntax parsing preserves exact text and line boundaries', () {
    const source = '// Comment\nfinal String value = "hello";\n';
    final parsed = parseGitCode(('main.dart', source));
    expect(
      parsed.lines.map((line) => line.map((span) => span.$1).join()).join('\n'),
      source,
    );
    expect(
      parsed.lines.expand((line) => line).any((s) => s.$2 == 'comment'),
      true,
    );
    expect(
      parsed.lines.expand((line) => line).any((s) => s.$2 == 'string'),
      true,
    );
    expect(findGitCode((source, 'HELLO')), [1]);
  });
  for (final width in [390.0, 1100.0]) {
    testWidgets('code browse, find and immutable location at $width pixels', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
      final text = [
        for (var i = 0; i < 1000; i++)
          i == 500 ? 'final needle = 42;' : '// line $i',
      ].join('\n');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GitCodeBrowser(
              repository: 'ournet://243dae92ba/Ournet',
              commit: 'a' * 40,
              path: 'lib/main.dart',
              text: text,
              initialLine: 400,
              entries: const [('lib', true), ('main.dart', false)],
            ),
          ),
        ),
      );
      await until(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Copy line link'));
      await tester.pump();
      expect(Uri.parse(copied!).fragment, 'L400');
      expect(Uri.parse(copied!).queryParameters['commit'], 'a' * 40);
      expect(Uri.parse(copied!).queryParameters['path'], 'lib/main.dart');
      await tester.enterText(find.byType(TextField), 'needle');
      await tester.pump(const Duration(milliseconds: 200));
      await until(tester, () => find.text('1/1').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('Copy line link'));
      await tester.pump();
      expect(Uri.parse(copied!).fragment, 'L501');
      await tester.tap(find.byTooltip('Copy file'));
      await tester.pump();
      expect(copied, text);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('network graph shows cross-lane parents and opens commits', (
    tester,
  ) async {
    NetworkCommit? selected;
    await tester.runAsync(() async {
      const base = 'C:/src/flutter/bin/cache/artifacts/material_fonts';
      if (Directory(base).existsSync()) {
        final loader = FontLoader('Roboto')
          ..addFont(
            File(
              '$base/roboto-regular.ttf',
            ).readAsBytes().then(ByteData.sublistView),
          );
        await loader.load();
      }
    });
    final shot = GlobalKey();
    final commits = [
      NetworkCommit(
        sha: 'a' * 40,
        repository: 'upstream',
        title: 'Merge feature',
        author: 'Alex',
        lane: 0,
        at: 1700000000000,
        parents: ['b' * 40, 'c' * 40],
        labels: const ['main'],
      ),
      NetworkCommit(
        sha: 'b' * 40,
        repository: 'fork',
        title: 'Fork change',
        author: 'Sam',
        lane: 1,
        at: 1699990000000,
        parents: ['c' * 40],
        labels: const ['feature'],
      ),
      NetworkCommit(
        sha: 'c' * 40,
        repository: 'upstream',
        title: 'Shared ancestor',
        author: 'Alex',
        lane: 0,
        at: 1699980000000,
        parents: const [],
        labels: const [],
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: shot,
            child: ColoredBox(
              color: Colors.white,
              child: GitNetworkView(
                commits: commits,
                lanes: const [
                  'Alex / OurNet · main',
                  'Sam / OurNet-fork · feature',
                ],
                onCommit: (c) => selected = c,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Fork change\nSam\n${'b' * 40}\nfeature'));
    expect(selected?.repository, 'fork');
    expect(selected?.sha, 'b' * 40);
    expect(tester.takeException(), isNull);
    const output = String.fromEnvironment('GIT_BROWSER_SHOTS');
    if (output.isNotEmpty) {
      await tester.pump();
      await tester.runAsync(() async {
        final image =
            await (shot.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(output).create(recursive: true);
        await File(
          '$output/network.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
