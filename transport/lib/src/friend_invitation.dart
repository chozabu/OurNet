part of 'network.dart';

/// Expiring single-use invitation. Does not enrol devices or share identity secrets.
class FriendSession {
  final PeerNetwork network;
  final Future<bool> Function(DeviceCertificate, String) confirm;
  final String token = b64(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );
  final DateTime expires = DateTime.now().add(const Duration(minutes: 5));
  bool _closed = false, _pending = false;
  String? acceptedPeer;
  final _cancelled = Completer<bool>();
  FriendSession(this.network, this.confirm) {
    if (!network.running) {
      throw StateError('Connect before inviting a friend');
    }
    network.friendInvitation?.close();
    network.friendInvitation = this;
  }
  bool get available => !_closed && DateTime.now().isBefore(expires);
  String get invitation => canonical({
    'friend': 1,
    'token': token,
    'expires': expires.millisecondsSinceEpoch,
    'card': jsonDecode(network.contactCard()),
  });
  static Json parse(String text) {
    if (text.length > 16384) throw StateError('Friend invitation is too large');
    final j = jsonDecode(text) as Json;
    if (j['friend'] != 1 ||
        j['token'] is! String ||
        (j['token'] as String).length != 44 ||
        j['expires'] is! int ||
        DateTime.now().millisecondsSinceEpoch >= j['expires']) {
      throw StateError(
        'Invalid or expired invitation. Create a new friend invitation.',
      );
    }
    final card = j['card'] as Json;
    final certificate = DeviceCertificate.fromJson(card['certificate']);
    if (card['version'] != 2 ||
        card['address'] is! String ||
        certificate.label.length > 80 ||
        certificate.device.isEmpty ||
        certificate.person.isEmpty) {
      throw StateError('Invalid friend invitation');
    }
    return j;
  }

  static String code(String token, DeviceCertificate certificate) => hash({
    'token': token,
    'device': certificate.toJson(),
  }).substring(0, 8).toUpperCase();
  Future<Json> approve(String peer, Json request) async {
    if (!available || _pending || request['token'] != token) {
      throw StateError('Friend unavailable');
    }
    final card = request['card'] as Json;
    final cert = DeviceCertificate.fromJson(card['certificate']);
    if (cert.device != peer || !await cert.valid())
      throw StateError('Invalid device');
    if (card['address'] == null ||
        b64(iroh.EndpointAddr.decode(unb64(card['address'])).id.asBytes()) !=
            peer) {
      throw StateError('Invalid device address');
    }
    if (!available || _pending) throw StateError('Friend unavailable');
    _pending = true;
    try {
      final accepted = await Future.any([
        confirm(cert, code(token, cert)),
        _cancelled.future,
      ]).timeout(const Duration(seconds: 90), onTimeout: () => false);
      if (!accepted || !available)
        return {'error': 'Friend declined or expired. Try again.'};
      if (cert.person == network.node.person)
        throw StateError('Use Add device for your own profile.');
      if (!available) return {'error': 'Invitation cancelled'};
      await network.addCard(canonical(card));
      acceptedPeer = peer;
      _closed = true;
      return {'accepted': true, 'card': jsonDecode(network.contactCard())};
    } finally {
      _pending = false;
    }
  }

  void close() {
    _closed = true;
    if (!_cancelled.isCompleted) _cancelled.complete(false);
  }

  static Future<void> join(PeerNetwork network, String invitation) async {
    final j = parse(invitation);
    final card = j['card'] as Json;
    final owner = DeviceCertificate.fromJson(card['certificate']);
    if (!await owner.valid()) throw StateError('Invalid owner');
    final address = iroh.EndpointAddr.decode(unb64(card['address']));
    if (b64(address.id.asBytes()) != owner.device)
      throw StateError('Invalid owner address');
    final ep = network._endpoint;
    if (ep == null) throw StateError('Network is stopped');
    var abandoned = false;
    final pending = ep.connect(address, PeerNetwork._alpn).then((connection) {
      if (abandoned || !identical(ep, network._endpoint)) {
        connection.close();
        throw StateError('Connection cancelled');
      }
      return connection;
    });
    late final iroh.Connection connection;
    try {
      connection = await pending.timeout(const Duration(seconds: 20));
    } catch (_) {
      abandoned = true;
      rethrow;
    }
    network._connections.add(connection);
    try {
      final (send, recv) = await connection.openBi();
      await send.writeAll(
        bytes({
          'type': 'friend',
          'token': j['token'],
          'card': jsonDecode(network.contactCard()),
        }),
      );
      await send.finish();
      final response =
          jsonDecode(
                utf8.decode(
                  await recv
                      .readToEnd(16384)
                      .timeout(const Duration(seconds: 100)),
                ),
              )
              as Json;
      if (response['error'] != null) throw StateError(response['error']);
      if (response['accepted'] != true)
        throw StateError('Invitation was not accepted.');
      final returned = DeviceCertificate.fromJson(
        (response['card'] as Json)['certificate'],
      );
      if (returned.device != owner.device || returned.person != owner.person)
        throw StateError('Unexpected friend identity');
      await network.addCard(canonical(card));
    } finally {
      connection.close();
      network._connections.remove(connection);
    }
  }
}
