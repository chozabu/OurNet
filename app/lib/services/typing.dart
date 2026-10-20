import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// "Typing…" between friends: a live request to devices seen recently, never
/// stored or forwarded. Sent at most every few seconds while typing; shown
/// for a few seconds after the last one arrives. Off in Settings stops both
/// sending and showing.
class Typing extends ChangeNotifier {
  final PeerNetwork network;
  Typing(this.network) {
    network.handle('typing', _onRequest, poolable: true);
  }

  static const _repeat = Duration(seconds: 4);
  static const _shown = Duration(seconds: 6);

  /// Devices are only told while they are around: it must never wake,
  /// dial or queue for a sleeping phone.
  static const _recent = Duration(minutes: 3);

  final _until = <String, DateTime>{};
  final _sent = <String, DateTime>{};

  /// Devices whose build refused the request; not asked again this run.
  final _refused = <String>{};
  // Slow/offline devices must not accumulate a new request on every burst.
  // Keep independent hints best-effort and bound their connection attempts.
  final _pending = <String>{};
  static const _maxPending = 8;
  Timer? _expiry;

  bool get enabled => network.node.store.setting('typingIndicator') != false;

  bool isTyping(String person) {
    final until = _until[person];
    return enabled && until != null && until.isAfter(DateTime.now());
  }

  Future<Json> _onRequest(String device, Json request) async {
    _received(device);
    return const {};
  }

  void _received(String device) {
    final person = network.node.contacts[device]?.person;
    if (person == null || !enabled) return;
    _until[person] = DateTime.now().add(_shown);
    _schedule();
    notifyListeners();
  }

  /// A message from [person] arrived, so they have stopped typing it.
  void clear(String person) {
    if (_until.remove(person) != null) notifyListeners();
  }

  void _schedule() {
    _expiry?.cancel();
    if (_until.isEmpty) return;
    final next = _until.values.reduce((a, b) => a.isBefore(b) ? a : b);
    _expiry = Timer(next.difference(DateTime.now()), () {
      final now = DateTime.now();
      _until.removeWhere((_, until) => !until.isAfter(now));
      _schedule();
      notifyListeners();
    });
  }

  /// This person is typing to [person]; tells their recently seen devices.
  void typed(String person) {
    if (!enabled || !network.running) return;
    final now = DateTime.now();
    final last = _sent[person];
    if (last != null && now.difference(last) < _repeat) return;
    _sent[person] = now;
    final node = network.node;
    for (final contact in node.contacts.values) {
      final device = contact.device;
      if (contact.person != person ||
          _refused.contains(device) ||
          _pending.contains(device) ||
          !node.allowedPeer(device)) {
        continue;
      }
      final seen = [
        network.lastInbound[device],
        network.lastSync[device],
      ].whereType<DateTime>().where((t) => now.difference(t) < _recent);
      if (seen.isEmpty) continue;
      if (_pending.length >= _maxPending) break;
      _pending.add(device);
      unawaited(
        network
            .request(device, {'type': 'typing'})
            .then<void>(
              (_) {},
              onError: (Object e) {
                if ('$e'.contains('Unknown request')) _refused.add(device);
              },
            )
            .whenComplete(() {
              _pending.remove(device);
            }),
      );
    }
  }

  /// A message was sent, so the next keystroke starts a new burst.
  void sent(String person) => _sent.remove(person);

  @override
  void dispose() {
    _expiry?.cancel();
    network.unhandle('typing', _onRequest);
    super.dispose();
  }
}
