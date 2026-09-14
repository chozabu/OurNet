import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';

/// Native files remain staged until publication succeeds. Per-part checkpoints
/// make repeated intents and interrupted imports safe to retry.
class ShareInbox {
  static const channel = MethodChannel('ournet/share');
  final Node node;
  final Future<void> Function(String, String) file;
  final void Function(String?) onResult;
  bool busy = false;
  ShareInbox(this.node, this.file, this.onResult);
  Future<void> start() async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') await drain();
    });
    await drain();
  }

  Future<void> drain() async {
    if (busy) return;
    busy = true;
    try {
      final shares = await channel.invokeListMethod<dynamic>('pending') ?? [];
      for (final raw in shares) {
        final share = Map<String, dynamic>.from(raw as Map);
        final id = share['id'] as String;
        final text = share['text'] as String;
        if (text.isNotEmpty && node.store.setting('share/$id/text') != true) {
          await Everyday(
            node,
          ).write({'type': 'note', 'text': text, 'entry': 'share/$id/text'});
          node.store.set('share/$id/text', true);
        }
        var index = 0;
        for (final rawFile in share['files'] as List) {
          final key = 'share/$id/${index++}';
          if (node.store.setting(key) == true) continue;
          final f = Map<String, dynamic>.from(rawFile as Map);
          await file(f['path'], f['name']);
          node.store.set(key, true);
        }
        await channel.invokeMethod<void>('ack', {'id': id});
        onResult((share['error'] as String).isEmpty ? null : share['error']);
      }
    } catch (e) {
      onResult('Share is waiting to import: $e');
    } finally {
      busy = false;
    }
  }

  void close() {
    channel.setMethodCallHandler(null);
  }
}
