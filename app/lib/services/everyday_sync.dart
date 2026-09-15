import 'dart:async';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// Durable objects are the queue. Only acknowledge after original chunks have
/// been verified and cached; metadata sync is never presented as file delivery.
class EverydaySync {
  final PeerNetwork network;
  final void Function() onUpdate;
  final void Function(SignedObject object, Json payload)? onCached;
  // Remembers acknowledged items so passes avoid a settings query per item.
  final _received = <String>{};
  late final Files files = Files(network.node, network);
  Timer? timer;
  bool busy = false, closed = false;
  final errors = <String, String>{};

  /// Note attachments (photos, drawings, recordings) waiting to be cached,
  /// found by an insertion cursor so passes never rescan note history.
  final _noteFiles = <String>{};
  int _noteCursor = 0;
  EverydaySync(this.network, this.onUpdate, {this.onCached}) {
    timer = Timer.periodic(const Duration(seconds: 15), (_) => sync());
  }
  Future<void> sync() async {
    if (busy || closed || !network.running) return;
    busy = true;
    var changed = false;
    try {
      for (final item in await Everyday(network.node).records()) {
        if (closed || !network.running) break;
        if (!['inbox', 'room_item'].contains(item.object.kind)) continue;
        if (_received.contains(item.object.id)) continue;
        final key = 'everyday/received/${item.object.id}';
        if (network.node.store.setting(key) == true) {
          _received.add(item.object.id);
          continue;
        }
        try {
          if (item.data['type'] == 'file') {
            await files.cache(item.object);
            onCached?.call(item.object, item.data);
          }
          if (item.object.certificate.device != network.node.identity.device) {
            await network.node.publish(
              'delivery',
              {'object': item.object.id},
              space: '_delivery',
              audience: item.object.audience,
            );
          }
          network.node.store.set(key, true);
          _received.add(item.object.id);
          changed = true;
          errors.remove(item.object.id);
        } catch (error) {
          final message = error.toString();
          if (errors[item.object.id] != message) changed = true;
          errors[item.object.id] = message;
          /* Retry this item on the next foreground pass. */
        }
      }
      changed = await _cacheNoteFiles() || changed;
    } finally {
      busy = false;
      if (!closed && changed) onUpdate();
    }
  }

  Future<bool> _cacheNoteFiles() async {
    final node = network.node;
    final slice = TimeSlice();
    while (true) {
      final page = node.store.insertedAfter(_noteCursor, ['note_op']);
      if (page.isEmpty) break;
      for (final (cursor, object) in page) {
        _noteCursor = cursor;
        final payload = await node.content(object);
        if (payload != null &&
            payload['chunks'] is List &&
            (payload['field'] as String).endsWith(':meta') &&
            !files.cached(payload)) {
          _noteFiles.add(object.id);
        }
        await slice.pause();
      }
    }
    var changed = false;
    for (final id in _noteFiles.toList()) {
      if (closed || !network.running) break;
      final object = node.store.get(id);
      final payload = object == null ? null : await node.content(object);
      if (object == null || payload == null) {
        _noteFiles.remove(id);
        continue;
      }
      try {
        await files.cache(object);
        _noteFiles.remove(id);
        errors.remove(id);
        onCached?.call(object, payload);
        changed = true;
      } catch (error) {
        errors[id] = '$error';
        /* A source device may come online later. */
      }
    }
    return changed;
  }

  void close() {
    closed = true;
    timer?.cancel();
  }
}
