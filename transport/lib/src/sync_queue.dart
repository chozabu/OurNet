import 'dart:async';
import 'dart:collection';

/// Coalesces requests per peer, retaining requests made during an exchange.
/// All callers wait until that peer's requested follow-up has also completed.
/// Waiting peers start in [order] (requested order when absent), so a peer
/// likely to answer need not wait behind ones likely to time out.
class SyncQueue {
  SyncQueue(this.exchange, {this.concurrency = 2, this.order});

  final Future<void> Function(String) exchange;
  final int concurrency;
  final Comparator<String>? order;
  final _waiting = LinkedHashSet<String>();
  final _active = <String>{};
  final _completion = <String, Completer<void>>{};

  Future<void> schedule(String device) {
    final completion = _completion.putIfAbsent(device, Completer<void>.new);
    _waiting.add(device);
    _drain();
    return completion.future;
  }

  void _drain() {
    while (_active.length < concurrency) {
      final available = _waiting.where((d) => !_active.contains(d));
      if (available.isEmpty) return;
      final order = this.order;
      final device = order == null
          ? available.first
          : available.reduce((a, b) => order(a, b) <= 0 ? a : b);
      _waiting.remove(device);
      _active.add(device);
      unawaited(_run(device));
    }
  }

  Future<void> _run(String device) async {
    try {
      await exchange(device);
    } catch (error, stack) {
      _waiting.remove(device);
      _completion.remove(device)!.completeError(error, stack);
    } finally {
      _active.remove(device);
      if (!_waiting.contains(device)) {
        _completion.remove(device)?.complete();
      }
      _drain();
    }
  }
}
