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
    } finally {
      busy = false;
      if (!closed && changed) onUpdate();
    }
  }

  void close() {
    closed = true;
    timer?.cancel();
  }
}
