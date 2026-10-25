import 'dart:developer' show Timeline;
import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/perf_support.dart';

void main() {
  testWidgets('delayed prior frames are separate and current slow frames stay measured', (tester) async {
    final recorder = PhaseRecorder(1000 / 60);
    final dispatcher = tester.binding.platformDispatcher;
    final original = dispatcher.onReportTimings;
    final before = Timeline.now;
    recorder.start();
    final deliver = dispatcher.onReportTimings!;
    // Keep actual engine delivery out of this synthetic batch.
    dispatcher.onReportTimings = (_) {};
    final current = Timeline.now + 1000;
    FrameTiming frame(int start, int build) => FrameTiming(
      vsyncStart: start, buildStart: start, buildFinish: start + build,
      rasterStart: start + build, rasterFinish: start + build + 1000,
      rasterFinishWallTime: 0,
    );
    late Map<String, Object> report;
    try {
      deliver([frame(before - 200000, 110000), frame(current, 45000)]);
      report = (await tester.runAsync(recorder.stop))!;
    } finally {
      dispatcher.onReportTimings = original;
    }
    expect(report['frames'], 1);
    expect(report['priorPhaseFrames'], 1);
    expect(report['priorPhaseFrameStageMaxMs'], 110);
    expect((report['frameStageMs'] as Map)['max'], 45);
    expect(report['framesOverTwoBudgets'], 1);
  });
}
