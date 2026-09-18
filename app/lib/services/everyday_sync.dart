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

  /// Group and inbox items waiting to be acknowledged, found the same way.
  final _items = <String>{};
  int _itemCursor = 0;
  EverydaySync(this.network, this.onUpdate, {this.onCached}) {
    timer = Timer.periodic(const Duration(seconds: 15), (_) => sync());
  }
  Future<void> sync() async {
    if (busy || closed || !network.running) return;
    busy = true;
    var changed = false;
    try {
      changed = await _cacheEverydayItems() || changed;
      changed = await _cacheNoteFiles() || changed;
    } finally {
      busy = false;
      if (!closed && changed) onUpdate();
    }
  }

  /// Acknowledges group and inbox items, and caches the files they carry.
  /// A pass reads only what has arrived since the last one; items that fail
  /// stay pending and are retried, so nothing depends on rescanning history.
  Future<bool> _cacheEverydayItems() async {
    final node = network.node;
    // Looking for a kind walks the rows in between whether or not any of them
    // are of that kind, so the cursor moves past everything scanned. A profile
    // of notes holds no group items at all, and this runs on a timer.
    final target = node.store.insertionCursor;
    final slice = TimeSlice();
    while (true) {
      final page = node.store.insertedAfter(_itemCursor, Everyday.itemKinds);
      if (page.isEmpty || closed) break;
      for (final (cursor, object) in page) {
        _itemCursor = cursor;
        await slice.pause();
        if (object.isPublic || _received.contains(object.id)) continue;
        if (node.store.setting('everyday/received/${object.id}') == true) {
          _received.add(object.id);
          continue;
        }
        _items.add(object.id);
      }
    }
    if (_itemCursor < target) _itemCursor = target;
    var changed = false;
    for (final id in _items.toList()) {
      if (closed || !network.running) break;
      final object = node.store.get(id);
      // Unreadable here means blocked, expired or not ours to decrypt. None
      // of those should be acknowledged as delivered.
      final payload = object == null ? null : await node.content(object);
      if (object == null || payload == null) {
        _items.remove(id);
        continue;
      }
      try {
        if (payload['type'] == 'file') {
          await files.cache(object);
          onCached?.call(object, payload);
        }
        if (object.certificate.device != node.identity.device) {
          await node.publish(
            'delivery',
            {'object': object.id},
            space: '_delivery',
            audience: object.audience,
          );
        }
        node.store.set('everyday/received/$id', true);
        _received.add(id);
        _items.remove(id);
        changed = true;
        errors.remove(id);
      } catch (error) {
        final message = error.toString();
        if (errors[id] != message) changed = true;
        errors[id] = message;
        /* Retry this item on the next foreground pass. */
      }
    }
    return changed;
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
