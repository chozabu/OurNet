import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:image/image.dart' as img;

/// Frame timings and event-loop delay (10 ms timer) for one journey phase.
/// On Android it also reports CPU time used by the thread running the UI
/// isolate (the platform thread, whose stalls become "not responding").
class PhaseRecorder {
  final double frameBudgetMs;
  PhaseRecorder(this.frameBudgetMs);
  final _timings = <FrameTiming>[];
  final _delays = <double>[];
  Timer? _timer;
  final _clock = Stopwatch();
  int _last = 0;

  void _onTimings(List<FrameTiming> timings) => _timings.addAll(timings);

  int? _uiCpuTicks;

  void start() {
    _uiCpuTicks = uiThreadCpuTicks();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _clock.start();
    _last = _clock.elapsedMicroseconds;
    _timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final now = _clock.elapsedMicroseconds;
      _delays.add(max(0, now - _last - 10000) / 1000);
      _last = now;
    });
  }

  Future<Map<String, Object>> stop() async {
    // The engine batches timing reports; wait for this phase's frames.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _timer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    double ms(Duration d) => d.inMicroseconds / 1000;
    final build = _timings.map((t) => ms(t.buildDuration)).toList()..sort();
    final raster = _timings.map((t) => ms(t.rasterDuration)).toList()..sort();
    final stage =
        _timings
            .map((t) => max(ms(t.buildDuration), ms(t.rasterDuration)))
            .toList()
          ..sort();
    final total = _timings.map((t) => ms(t.totalSpan)).toList()..sort();
    double pct(List<double> v, double p) =>
        v.isEmpty ? 0 : v[max(0, (v.length * p).ceil() - 1)];
    Map<String, double> summary(List<double> v) => {
      'p50': pct(v, .5),
      'p90': pct(v, .9),
      'p95': pct(v, .95),
      'p99': pct(v, .99),
      'max': v.isEmpty ? 0 : v.last,
    };
    final ticks = uiThreadCpuTicks();
    return {
      if (ticks != null && _uiCpuTicks != null)
        'uiThreadCpuMs': (ticks - _uiCpuTicks!) * 10,
      'wallMs': _clock.elapsedMilliseconds,
      'frames': _timings.length,
      'framesOverBudget': stage.where((v) => v > frameBudgetMs).length,
      'framesOverTwoBudgets': stage.where((v) => v > 2 * frameBudgetMs).length,
      'frameStageMs': summary(stage),
      'buildMs': summary(build),
      'rasterMs': summary(raster),
      'totalSpanMs': summary(total),
      'eventLoopDelayMs': summary(_delays..sort()),
    };
  }
}

/// User+system clock ticks (10 ms) of the current thread, where available.
/// Tests call it from the UI isolate, so on Android this is the main thread.
int? uiThreadCpuTicks() {
  try {
    final stat = File('/proc/thread-self/stat').readAsStringSync();
    final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    return int.parse(fields[11]) + int.parse(fields[12]);
  } catch (_) {
    return null;
  }
}

/// Deterministic photo-like JPEG: smooth lighting, large shapes and sensor
/// noise so size and decode cost resemble a phone camera image.
Uint8List makePhoto(int seed, int width, int height) {
  final random = Random(seed);
  final image = img.Image(width: width, height: height);
  final cx = random.nextDouble() * width, cy = random.nextDouble() * height;
  final hue = random.nextDouble();
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final d = sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) / width;
      final band = (sin(x / 37.0 + seed) + cos(y / 53.0)) * 18;
      final n = random.nextInt(24) - 12;
      int c(double phase) =>
          (128 + 90 * sin(hue * 6.28 + phase - d * 3) + band + n)
              .clamp(0, 255)
              .toInt();
      image.setPixelRgb(x, y, c(0), c(2.1), c(4.2));
    }
  }
  return img.encodeJpg(image, quality: 90);
}

Future<List<File>> fixtures(Directory cache, int count, int w, int h) async {
  final result = <File>[];
  for (var i = 0; i < count; i++) {
    final file = File('${cache.path}/photo-v1-$w-$h-$i.jpg');
    if (!await file.exists()) {
      final bytes = await compute(
        (int seed) => makePhoto(seed, w, h),
        1000 + i,
      );
      await file.writeAsBytes(bytes, flush: true);
    }
    result.add(file);
  }
  return result;
}
