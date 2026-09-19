import 'dart:async';
import 'package:ournet_core/ournet_core.dart';

/// This person's recent private messages that some recipient device has not
/// acknowledged yet (no receipt). While there are any, staying online a
/// little longer lets them go out.
class Undelivered {
  final Node node;
  Undelivered(this.node);

  int _cursor = 0;
  StreamSubscription<void>? _changes;

  /// Unacknowledged message IDs per recipient device, with when each was seen.
  final _waiting = <String, Map<String, DateTime>>{};

  /// Messages older than this are no longer waited for.
  static const _patience = Duration(minutes: 10);

  void start() {
    _cursor = node.store.insertionCursor;
    _changes = node.changes.stream.listen((_) => _scan());
  }

  void _scan() {
    final now = DateTime.now();
    while (true) {
      final page = node.store.insertedAfter(_cursor, ['message']);
      for (final (sequence, o) in page) {
        _cursor = sequence;
        if (o.author != node.person || o.isPublic) continue;
        for (final device in node.contacts.values) {
          if (device.person != node.person &&
              o.audience.contains(device.person) &&
              !node.revoked.contains(device.device)) {
            (_waiting[device.device] ??= {})[o.id] = now;
          }
        }
      }
      if (page.length < 128) break;
    }
  }

  bool _received(String device, String id) => node.store
      .evidence(id)
      .any(
        (e) =>
            e.data['domain'] == 'ournet/receipt/2' &&
            e.certificate.device == device,
      );

  /// Whether any recent message still lacks a receipt from a recipient.
  bool get any {
    final oldest = DateTime.now().subtract(_patience);
    for (final device in _waiting.keys.toList()) {
      final ids = _waiting[device]!
        ..removeWhere(
          (id, seen) => seen.isBefore(oldest) || _received(device, id),
        );
      if (ids.isEmpty) _waiting.remove(device);
    }
    return _waiting.isNotEmpty;
  }

  void close() => _changes?.cancel();
}
