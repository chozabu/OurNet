import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/coalesced_task.dart';
import 'package:ournet/services/performance.dart';

void main() {
  testWidgets(
    'refresh bursts do not overlap and changes during a run are retained',
    (tester) async {
      var calls = 0;
      final first = Completer<void>();
      final task = CoalescedTask(() async {
        calls++;
        if (calls == 1) await first.future;
      }, (e) => fail('$e'));
      for (var i = 0; i < 100; i++) {
        task.schedule();
      }
      await tester.pump(const Duration(milliseconds: 40));
      expect(calls, 1);
      for (var i = 0; i < 100; i++) {
        task.schedule();
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, 1);
      first.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(calls, 2);
      task.schedule();
      task.close();
      await tester.pump(const Duration(milliseconds: 40));
      expect(calls, 2);
    },
  );

  test('diagnostics use bounded samples but retain the worst stall', () {
    final samples = TimingSamples()..add(1000);
    for (var i = 0; i < 1000; i++) {
      samples.add(1);
    }
    expect(samples.snapshot(), {
      'count': 1001,
      'windowCount': 600,
      'p95': 1.0,
      'p99': 1.0,
      'max': 1000.0,
    });
  });
}
