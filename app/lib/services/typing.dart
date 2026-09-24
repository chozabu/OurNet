import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// "Typing…" between friends: a live request to devices seen recently, never
/// stored or forwarded. Sent at most every few seconds while typing; shown
/// for a few seconds after the last one arrives. Off in Settings stops both
/// sending and showing.
class Typing extends ChangeNotifier {
  final PeerNetwork network;
  Typing(this.network) {
    network.typing = _received;
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
  Timer? _expiry;

  bool get enabled => network.node.store.setting('typingIndicator') != false;

  bool isTyping(String person) {
    final until = _until[person];
    return enabled && until != null && until.isAfter(DateTime.now());
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
          !node.allowedPeer(device)) {
        continue;
      }
      final seen = [
        network.lastInbound[device],
        network.lastSync[device],
      ].whereType<DateTime>().where((t) => now.difference(t) < _recent);
      if (seen.isEmpty) continue;
      unawaited(
        network
            .request(device, {'type': 'typing'})
            .then<void>(
              (_) {},
              onError: (Object e) {
                if ('$e'.contains('Unknown request')) _refused.add(device);
              },
            ),
      );
    }
  }

  /// A message was sent, so the next keystroke starts a new burst.
  void sent(String person) => _sent.remove(person);

  @override
  void dispose() {
    _expiry?.cancel();
    if (network.typing == _received) network.typing = null;
    super.dispose();
  }
}
