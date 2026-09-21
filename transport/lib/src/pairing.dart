part of 'network.dart';

/// Only alive while the owner explicitly opens Add device. QUIC authenticates
/// the request device; the invitation pins the owner's endpoint and identity.
///
/// Any device holding the root can open one: [root] is the root unlocked with
/// the recovery phrase, held only while the session is open.
class PairingSession {
  final PeerNetwork network;
  final Future<bool> Function(DeviceCertificate, String) confirm;
  SimpleKeyPair? _root;

  /// Whether the new device also gets this device's sealed copy of the root,
  /// so that it too can add and remove devices. Read when approving.
  bool shareRoot = true;
  final String token = b64(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );
  final DateTime expires = DateTime.now().add(const Duration(minutes: 5));
  bool _closed = false, _pending = false;
  final _cancelled = Completer<bool>();
  PairingSession(this.network, this.confirm, {SimpleKeyPair? root})
    : _root = root ?? network.node.identity.root {
    if (_root == null) {
      throw StateError(
        network.node.identity.holdsRoot
            ? 'Enter your recovery phrase to add a device'
            : 'This device cannot add devices. Use one that can.',
      );
    }
    if (!network.running) throw StateError('Network is stopped');
    network.pairing?.close();
    network.pairing = this;
  }
  bool get available => !_closed && DateTime.now().isBefore(expires);
  String get invitation => canonical({
    'pairing': 1,
    'token': token,
    'expires': expires.millisecondsSinceEpoch,
    'card': jsonDecode(network.contactCard()),
  });
  static Json parse(String text) {
    if (text.length > 16384)
      throw StateError('Pairing invitation is too large');
    final j = jsonDecode(text) as Json;
    if (j['pairing'] != 1 ||
        j['token'] is! String ||
        (j['token'] as String).length != 44 ||
        j['expires'] is! int ||
        DateTime.now().millisecondsSinceEpoch >= j['expires']) {
      throw StateError('Invalid or expired invitation. Open Add device again.');
    }
    final card = j['card'] as Json;
    final certificate = DeviceCertificate.fromJson(card['certificate']);
    if (card['version'] != 2 ||
        card['address'] is! String ||
        certificate.label.length > 80 ||
        certificate.device.isEmpty ||
        certificate.person.isEmpty) {
      throw StateError('Invalid pairing invitation');
    }
    return j;
  }

  static String code(String token, DeviceCertificate certificate) => hash({
    'token': token,
    'device': certificate.toJson(),
  }).substring(0, 8).toUpperCase();
  Future<Json> approve(String peer, Json request) async {
    if (!available || _pending || request['token'] != token) {
      throw StateError('Pairing unavailable');
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
    if (!available || _pending) throw StateError('Pairing unavailable');
    _pending = true;
    try {
      final accepted = await Future.any([
        confirm(cert, code(token, cert)),
        _cancelled.future,
      ]).timeout(const Duration(seconds: 90), onTimeout: () => false);
      if (!accepted || !available)
        return {'error': 'Pairing declined or expired. Try again.'};
      final approval = await network.node.identity.authorise(
        cert,
        unlocked: _root,
      );
      final sealed = shareRoot ? network.node.identity.sealedRoot : null;
      if (!available) return {'error': 'Pairing cancelled'};
      await network.addCard(
        canonical({...card, 'certificate': approval.toJson()}),
      );
      _closed = true;
      return {
        'approval': approval.toJson(),
        'card': jsonDecode(network.contactCard()),
        'sealedRoot': ?sealed?.toJson(),
      };
    } finally {
      _pending = false;
    }
  }

  void close() {
    _closed = true;
    _root = null;
    if (!_cancelled.isCompleted) _cancelled.complete(false);
  }

  static Future<LocalIdentity> join(
    PeerNetwork network,
    String invitation,
  ) async {
    if (network.node.store.count != 0)
      throw StateError('Use a fresh profile to connect');
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
          'type': 'pair',
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
      final approval = DeviceCertificate.fromJson(response['approval']);
      if (approval.person != owner.person)
        throw StateError('Unexpected profile');
      final sealed = response['sealedRoot'] == null
          ? null
          : SealedRoot.fromJson(response['sealedRoot']);
      final identity = await network.node.identity.enrol(
        approval,
        sealedRoot: sealed,
      );
      await network.addCard(canonical(card));
      return identity;
    } finally {
      connection.close();
      network._connections.remove(connection);
    }
  }
}
