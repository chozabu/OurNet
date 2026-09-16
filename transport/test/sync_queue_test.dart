import 'dart:async';

import 'package:ournet_transport/src/sync_queue.dart';
import 'package:test/test.dart';

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test('a request during exchange is retained and awaited', () async {
    final gates = <Completer<void>>[];
    final queue = SyncQueue((_) {
      final gate = Completer<void>();
      gates.add(gate);
      return gate.future;
    });
    var finished = false;
    final first = queue.schedule('a').then((_) => finished = true);
    final next = queue.schedule('a');
    final duplicate = queue.schedule('a');
    gates.first.complete();
    await tick();
    expect(gates, hasLength(2));
    expect(finished, isFalse);
    gates.last.complete();
    await Future.wait([first, next, duplicate]);
    expect(finished, isTrue);
    expect(gates, hasLength(2));
  });

  test(
    'all triggers share the concurrency limit and queued peers coalesce',
    () async {
      final gates = <String, Completer<void>>{};
      final calls = <String>[];
      var active = 0;
      var peak = 0;
      final queue = SyncQueue((device) async {
        calls.add(device);
        active++;
        if (active > peak) peak = active;
        await (gates[device] = Completer<void>()).future;
        active--;
      });
      final jobs = [
        for (final d in ['a', 'b', 'c', 'c', 'd']) queue.schedule(d),
      ];
      expect(calls, ['a', 'b']);
      gates['a']!.complete();
      await tick();
      expect(calls, ['a', 'b', 'c']);
      gates['b']!.complete();
      await tick();
      gates['c']!.complete();
      gates['d']!.complete();
      await Future.wait(jobs);
      expect(peak, 2);
      expect(calls, ['a', 'b', 'c', 'd']);
    },
  );

  test('failed exchange releases the slot and can be retried', () async {
    var fail = true;
    final queue = SyncQueue((_) async {
      if (fail) throw StateError('offline');
    }, concurrency: 1);
    await expectLater(queue.schedule('a'), throwsStateError);
    fail = false;
    await queue.schedule('a');
    await queue.schedule('b');
  });
}
