import 'dart:async';

/// Collapses bursts and permits at most one running task plus one rerun.
class CoalescedTask {
  final Future<void> Function() run;
  final void Function(Object) onError;
  final Duration delay;
  Timer? _timer;
  bool _running = false, _dirty = false, _closed = false;

  CoalescedTask(
    this.run,
    this.onError, {
    this.delay = const Duration(milliseconds: 32),
  });

  void schedule() {
    if (_closed) return;
    _dirty = true;
    if (_running || _timer != null) return;
    _timer = Timer(delay, _drain);
  }

  Future<void> _drain() async {
    _timer = null;
    if (_closed) return;
    _dirty = false;
    _running = true;
    try {
      await run();
    } catch (error) {
      if (!_closed) onError(error);
    } finally {
      _running = false;
      if (_dirty && !_closed) schedule();
    }
  }

  void close() {
    _closed = true;
    _timer?.cancel();
  }
}
