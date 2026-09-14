import 'dart:async';
import 'package:ournet_core/ournet_core.dart';
import 'files.dart';
import 'network.dart';

class DriveSync {
  final PeerNetwork network;
  late final Files files = Files(network.node, network);
  final void Function()? onUpdate;
  StreamSubscription<void>? _content, _network;
  Timer? _timer;
  Future<void>? _active;
  bool _closed = false;
  String? error;
  bool get enabled => network.node.store.setting('drive/offline') == true;
  bool get busy => _active != null;
  DriveSync(this.network, {this.onUpdate}) {
    _content = network.node.changes.stream.listen((_) => schedule());
    _network = network.updates.stream.listen((_) => schedule());
  }
  void setEnabled(bool value) {
    network.node.store.set('drive/offline', value);
    schedule();
    onUpdate?.call();
  }

  void schedule() {
    if (_closed) return;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), () => sync());
  }

  Future<void> sync() async {
    if (_closed || !enabled || !network.running || _active != null) return;
    final job = _download();
    _active = job;
    onUpdate?.call();
    try {
      await job;
    } finally {
      _active = null;
      onUpdate?.call();
    }
  }

  Future<void> _download() async {
    error = null;
    try {
      for (final entry in await Drive(network.node).entries()) {
        for (final version in entry.heads) {
          if (_closed || !enabled || !network.running) return;
          if (!version.deleted &&
              !version.isFolder &&
              !files.cached(version.data))
            await files.cache(version.object);
        }
      }
    } catch (e) {
      error = '$e';
    }
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    await _content?.cancel();
    await _network?.cancel();
    await _active;
  }
}
