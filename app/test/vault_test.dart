import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/vault.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vault_test');
  });

  tearDown(() => directory.delete(recursive: true));

  test('file vault keeps, replaces and deletes a secret', () async {
    final vault = FileVault(directory.path);
    expect(await vault.read('ournet/v2/main'), isNull);
    await vault.write('ournet/v2/main', 'first');
    await vault.write('ournet/v2/main', 'second');
    expect(await FileVault(directory.path).read('ournet/v2/main'), 'second');
    expect(await vault.read('ournet/v2/other'), isNull);
    await vault.delete('ournet/v2/main');
    expect(await vault.read('ournet/v2/main'), isNull);
    await vault.delete('ournet/v2/main');
  });

  test('file vault secrets are readable only by their owner', () async {
    final vault = FileVault(directory.path);
    await vault.write('ournet/v2/main', 'secret');
    final file = directory.listSync().whereType<File>().single;
    expect(file.statSync().mode & 0x1ff, 0x180);
    expect(file.path, isNot(endsWith('.next')));
  }, skip: Platform.isWindows);
}
