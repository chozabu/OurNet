import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';

/// Bounded, local-only measurements. No content, file paths or keys are kept.
class PerformanceMonitor {
  /// With [idleAfter], event-loop sampling (20 wakeups a second) pauses once
  /// nothing has been drawn or touched for that long, and resumes with the
  /// next frame or pointer event. Without it, sampling runs from [start] to
  /// [stop], as measurement runs need.
  PerformanceMonitor({this.idleAfter});
  final Duration? idleAfter;
  final frames = TimingSamples();
  final builds = TimingSamples();
  final rasters = TimingSamples();
  final eventLoop = TimingSamples();
  final _clock = Stopwatch();
  Timer? _timer;
  int _lastTick = 0;
  int _lastActive = 0;
  bool _started = false, _frameHook = false;

  void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(_onFrames);
    _clock.start();
    if (idleAfter != null) {
      // Persistent frame callbacks cannot be removed; this one checks
      // [_started] instead.
      if (!_frameHook) {
        _frameHook = true;
        SchedulerBinding.instance.addPersistentFrameCallback((_) => _active());
      }
      GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
    }
    _active();
  }

  void _pointer(PointerEvent _) => _active();

  void _active() {
    if (!_started) return;
    final now = _clock.elapsedMicroseconds;
    _lastActive = now;
    if (_timer != null) return;
    _lastTick = now;
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final now = _clock.elapsedMicroseconds;
      eventLoop.add(math.max(0, now - _lastTick - 50000) / 1000);
      _lastTick = now;
      final idle = idleAfter;
      if (idle != null && now - _lastActive > idle.inMicroseconds) {
        _timer?.cancel();
        _timer = null;
      }
    });
  }

  void _onFrames(List<FrameTiming> timings) {
    for (final timing in timings) {
      builds.add(timing.buildDuration.inMicroseconds / 1000);
      rasters.add(timing.rasterDuration.inMicroseconds / 1000);
      frames.add(
        math.max(
              timing.buildDuration.inMicroseconds,
              timing.rasterDuration.inMicroseconds,
            ) /
            1000,
      );
    }
  }

  Map<String, Object> snapshot() => {
    'buildMode': kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug',
    // Frame budgets depend on the display, e.g. 8.3 ms at 120 Hz.
    'refreshRateHz':
        PlatformDispatcher.instance.views.firstOrNull?.display.refreshRate ?? 0,
    'frameStageMs': frames.snapshot(),
    'buildMs': builds.snapshot(),
    'rasterMs': rasters.snapshot(),
    'eventLoopDelayMs': eventLoop.snapshot(),
    'sampleCapacity': TimingSamples.capacity,
  };

  void stop() {
    if (!_started) return;
    _started = false;
    _timer?.cancel();
    _timer = null;
    _clock.stop();
    SchedulerBinding.instance.removeTimingsCallback(_onFrames);
    if (idleAfter != null) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
    }
  }
}

class TimingSamples {
  static const capacity = 600;
  final _values = ListQueue<double>();
  int count = 0;
  double maximum = 0;

  void add(double milliseconds) {
    count++;
    maximum = math.max(maximum, milliseconds);
    if (_values.length == capacity) _values.removeFirst();
    _values.add(milliseconds);
  }

  Map<String, Object> snapshot() {
    final sorted = _values.toList()..sort();
    double percentile(double p) =>
        sorted.isEmpty ? 0 : sorted[(sorted.length * p).ceil() - 1];
    return {
      'count': count,
      'windowCount': sorted.length,
      'p95': percentile(.95),
      'p99': percentile(.99),
      'max': maximum,
    };
  }
}
