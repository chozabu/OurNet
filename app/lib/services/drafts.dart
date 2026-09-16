import 'dart:async';
import 'dart:isolate';
import 'package:ournet_core/ournet_core.dart';

/// Local-only drafts, encrypted for this device and written after typing pauses.
class DraftStore {
  final Node node;
  final values = <String, String>{};
  final _changed = <String>{};
  Timer? _timer;
  Future<void> _writes = Future.value();
  late final Future<void> ready = _load();
  DraftStore(this.node);

  Future<void> _load() async {
    final saved = node.store.setting('drafts/v1');
    if (saved == null) return;
    final plain = await decryptFor(
      Map<String, dynamic>.from(saved),
      node.identity,
    );
    for (final entry in plain.entries) {
      if (!_changed.contains(entry.key) && entry.value is String) {
        values[entry.key] = entry.value as String;
      }
    }
  }

  void put(String key, String text, void Function(Object) onError) {
    if (values[key] == text) return;
    _changed.add(key);
    values[key] = text;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), () {
      unawaited(flush().catchError(onError));
    });
  }

  Future<void> flush() {
    _timer?.cancel();
    _writes = _writes.catchError((Object _) {}).then((_) async {
      await ready;
      if (_changed.isEmpty) return;
      final snapshot = <String, dynamic>{
        for (final entry in values.entries)
          if (entry.value.isNotEmpty) entry.key: entry.value,
      };
      _changed.clear();
      try {
        final encrypted = node.store.path == null
            ? await encryptFor(snapshot, [node.identity.certificate])
            : await _encryptDraft(snapshot, node.identity.certificate);
        node.store.set('drafts/v1', encrypted);
      } catch (_) {
        _changed.addAll(values.keys);
        rethrow;
      }
    });
    return _writes;
  }
}

// Lifecycle flushes must not encrypt the draft collection on Flutter's UI
// isolate. _writes serializes snapshots; only a public certificate is sent.
Future<Json> _encryptDraft(Json snapshot, DeviceCertificate certificate) =>
    Isolate.run(
      () => encryptFor(snapshot, [certificate]),
      debugName: 'ournet-draft-save',
    );
