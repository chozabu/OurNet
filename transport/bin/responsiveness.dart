import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// Measures the real disk attachment pipeline, including cold worker startup.
/// This is an event-loop benchmark, not a Flutter frame/rendering benchmark.
Future<void> main(List<String> arguments) async {
  final directory = await Directory.systemTemp.createTemp('ournet-responsive-');
  final node = Node(
    await LocalIdentity.create(),
    Store(path: '${directory.path}/profile.db'),
  );
  final files = Files(node, PeerNetwork(node));
  final source = File('${directory.path}/payload.bin');
  final bytes = Uint8List.fromList(
    List.generate(8 * 1024 * 1024, (i) => i % 251),
  );
  final results = <String, Object>{
    'utc': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystem,
    'dart': Platform.version,
    'fileBytes': bytes.length,
    'description':
        'Local disk pipeline; no Flutter rendering or network transfer',
  };
  Future<void> measure(String name, Future<void> Function() action) async {
    final watch = Stopwatch()..start();
    var last = 0;
    final delays = <double>[];
    final heartbeat = Timer.periodic(const Duration(milliseconds: 8), (_) {
      final now = watch.elapsedMicroseconds;
      delays.add(max(0, now - last - 8000) / 1000);
      last = now;
    });
    try {
      await action();
      final elapsed = watch.elapsedMicroseconds / 1000;
      // Let a delayed timer report the final chunk too.
      await Future<void>.delayed(const Duration(milliseconds: 16));
      delays.sort();
      results[name] = {
        'elapsedMs': elapsed,
        'eventLoopSamples': delays.length,
        'eventLoopP95Ms': delays.isEmpty
            ? 0
            : delays[(delays.length * .95).ceil() - 1],
        'eventLoopMaxMs': delays.isEmpty ? 0 : delays.last,
      };
    } finally {
      heartbeat.cancel();
    }
  }

  try {
    await source.writeAsBytes(bytes);
    late SignedObject object;
    await measure('coldImport', () async {
      object = await files.publish(source.path, audience: [node.person]);
    });
    await measure('preview', () async {
      final actual = await files.readBytes(object);
      if (actual.length != bytes.length) throw StateError('Incomplete preview');
      for (var i = 0; i < actual.length; i++) {
        if (actual[i] != bytes[i]) throw StateError('Incorrect preview');
      }
    });
    results['rssBytes'] = ProcessInfo.currentRss;
    final json = const JsonEncoder.withIndent('  ').convert(results);
    stdout.writeln(json);
    if (arguments.isNotEmpty)
      await File(arguments.first).writeAsString('$json\n');
  } finally {
    await node.close();
    for (final file in await directory.list().toList()) {
      await file.delete();
    }
    await directory.delete();
  }
}
