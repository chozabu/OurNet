import 'dart:io';
import 'dart:typed_data';
import 'package:ournet_core/src/plugin_index.dart';
import 'package:test/test.dart';

void main() {
  test(
    'derived indexes persist, isolate plugins and grow past the settings quota',
    () async {
      final temp = await Directory.systemTemp.createTemp('ournet-index-test');
      addTearDown(() => temp.delete(recursive: true));
      final path = '${temp.path}/indexes.sqlite';
      var index = PluginIndex(path);
      // More than the old 16 MiB guest storage quota, in bounded batches.
      final value = Uint8List(4096)..[0] = 42;
      for (var batch = 0; batch < 34; batch++) {
        await index.request(
          'git',
          'put',
          'repo',
          entries: [
            for (var i = 0; i < 128; i++) ('${batch * 128 + i}', value),
          ],
        );
      }
      expect(await index.request('other', 'get', 'repo', key: '0'), isNull);
      expect(await index.request('git', 'get', 'repo', key: '0'), value);
      await index.close();
      index = PluginIndex(path);
      expect(await index.request('git', 'get', 'repo', key: '4351'), value);
      await index.request('git', 'clear', 'repo');
      expect(await index.request('git', 'get', 'repo', key: '0'), isNull);
      await index.close();
    },
  );
  test(
    'one million derived object locations stay on disk',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ournet-index-million',
      );
      addTearDown(() => temp.delete(recursive: true));
      final path = '${temp.path}/index.sqlite';
      var index = PluginIndex(path);
      final value = Uint8List(81)..[0] = 17;
      for (var start = 0; start < 1000000; start += 512) {
        await index.request(
          'git',
          'put',
          'objects/repo',
          entries: [
            for (var n = start; n < start + 512 && n < 1000000; n++)
              (n.toRadixString(16).padLeft(40, '0'), value),
          ],
        );
      }
      await index.close();
      expect(await File(path).length(), greaterThan(16 * 1024 * 1024));
      index = PluginIndex(path);
      for (final n in [0, 1, 10000, 500000, 999999]) {
        expect(
          await index.request(
            'git',
            'get',
            'objects/repo',
            key: n.toRadixString(16).padLeft(40, '0'),
          ),
          value,
        );
      }
      await index.close();
    },
    skip: Platform.environment['OURNET_INDEX_SCALE'] != '1'
        ? 'Opt in with OURNET_INDEX_SCALE=1'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
