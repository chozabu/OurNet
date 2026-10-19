/// A file being stored (imported) or fetched, with its progress, for the
/// app to show and cancel one at a time.
class Transfer {
  Transfer._(this._owner, this.id, this.name, this.total, this.upload);
  final Transfers _owner;
  final int id;
  final String name;

  /// Its size in bytes.
  final int total;

  /// Whether it is being stored here (true) or fetched (false).
  final bool upload;

  /// Bytes done so far.
  int get done => _done;
  int _done = 0;

  bool get cancelled => _cancelled;
  bool _cancelled = false;

  /// Stops it before its next chunk. A cancelled import can be started again
  /// and carries on where it stopped; a fetch keeps the chunks it has.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _owner._notify();
  }

  /// Throws [TransferCancelled] once [cancel] has been called.
  void check() {
    if (_cancelled) throw TransferCancelled(name);
  }

  void progress(int done) {
    final before = total == 0 ? 0 : _done * 100 ~/ total;
    _done = done;
    final after = total == 0 ? 0 : _done * 100 ~/ total;
    // Each percent at most, so a big file does not redraw per chunk.
    if (after != before) _owner._notify();
  }

  void finish() {
    if (_owner._active.remove(id) != null) _owner._notify();
  }
}

/// Thrown when a [Transfer] is cancelled.
class TransferCancelled extends StateError {
  TransferCancelled(String name) : super('Cancelled: $name');
}

/// The transfers of one node's files that are worth showing: those of large
/// files, which take long enough for someone to want to see or stop them.
class Transfers {
  final _active = <int, Transfer>{};
  final _listeners = <void Function()>{};
  var _next = 0;

  /// Files this size or larger are shown.
  static int shownFrom = 8 * 1024 * 1024;

  List<Transfer> get active => List.unmodifiable(_active.values);

  Transfer start(String name, int total, {required bool upload}) {
    final transfer = Transfer._(this, _next++, name, total, upload);
    if (total >= shownFrom) {
      _active[transfer.id] = transfer;
      _notify();
    }
    return transfer;
  }

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final listener in _listeners.toList()) {
      listener();
    }
  }
}
