import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rfw/formats.dart';

/// Every plugin's interface parses, so a typo fails here rather than as an
/// empty page.
void main() {
  final plugins = Directory('../plugins')
      .listSync()
      .whereType<Directory>()
      .where((d) => File('${d.path}/ui.rfwtxt').existsSync());

  test('there are plugin interfaces to check', () {
    expect(plugins, isNotEmpty);
  });

  for (final dir in plugins) {
    final name = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    test('$name/ui.rfwtxt parses', () {
      final library = parseLibraryFile(
        File('${dir.path}/ui.rfwtxt').readAsStringSync(),
      );
      expect(library.widgets, isNotEmpty);
      expect(
        library.imports.map((i) => i.name.parts.join('.')),
        everyElement(isIn(['core.widgets', 'core.material', 'ournet'])),
      );
    });
  }
}
