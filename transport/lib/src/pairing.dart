part of 'network.dart';

/// Whether [j] is an invitation of [type]: `{type, v: 1}`, or the form builds
/// before it wrote, which named the type as a top-level key set to 1.
bool isInvitation(Json j, String type) =>
    (j['type'] == type && j['v'] == 1) || j[type] == 1;

/// What both devices show, so the people holding them can see that each is
/// talking to the other. 48 bits of the hash of the token and certificate,
/// as three groups of four: `ABCD-EFGH-IJKL`. The first eight characters are
/// the code builds before it showed, so mixed versions still match by eye.
String confirmationCode(String token, DeviceCertificate certificate) {
  final digits = hash({
    'token': token,
    'device': certificate.toJson(),
  }).substring(0, 12).toUpperCase();
  return '${digits.substring(0, 4)}-${digits.substring(4, 8)}-${digits.substring(8)}';
}

/// Parses an invitation of [type], throwing [expired] when it is malformed or
/// out of date and `Invalid [what] invitation` when its card is unusable.
Json _parseInvitation(String text, String type, String what, String expired) {
  if (text.length > 16384) throw StateError('$what invitation is too large');
  final j = jsonDecode(text) as Json;
  if (!isInvitation(j, type) ||
      j['token'] is! String ||
      (j['token'] as String).length != 44 ||
      j['expires'] is! int ||
      DateTime.now().millisecondsSinceEpoch >= j['expires']) {
    throw StateError(expired);
  }
  final card = j['card'] as Json;
  final certificate = DeviceCertificate.fromJson(card['certificate']);
  if (card['version'] != 2 ||
      card['address'] is! String ||
      certificate.label.length > 80 ||
      certificate.device.isEmpty ||
      certificate.person.isEmpty) {
    throw StateError('Invalid ${what.toLowerCase()} invitation');
  }
  return j;
}

/// What pairing and friend invitations share: an expiring single-use token
/// that the person holding this device confirms by code.
abstract class _InvitationSession {
  final PeerNetwork network;
  final Future<bool> Function(DeviceCertificate, String) confirm;
  final String token = b64(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );
  final DateTime expires = DateTime.now().add(const Duration(minutes: 5));
  bool _closed = false, _pending = false;
  final _cancelled = Completer<bool>();
  _InvitationSession(this.network, this.confirm);

  /// The invitation's `type`, and the word its errors start with.
  String get _type;
  String get _noun;

  /// Called once the person confirmed [cert]; answers the requester.
  Future<Json> _accept(String peer, Json card, DeviceCertificate cert);

  bool get available => !_closed && DateTime.now().isBefore(expires);
  String get invitation => canonical({
    'type': _type,
    'v': 1,
    'token': token,
    'expires': expires.millisecondsSinceEpoch,
    'card': jsonDecode(network.contactCard()),
  });

  Future<Json> approve(String peer, Json request) async {
    if (!available || _pending || request['token'] != token) {
      throw StateError('$_noun unavailable');
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
    if (!available || _pending) throw StateError('$_noun unavailable');
    _pending = true;
    try {
      final accepted = await Future.any([
        confirm(cert, confirmationCode(token, cert)),
        _cancelled.future,
      ]).timeout(const Duration(seconds: 90), onTimeout: () => false);
      if (!accepted || !available)
        return {'error': '$_noun declined or expired. Try again.'};
      return await _accept(peer, card, cert);
    } finally {
      _pending = false;
    }
  }

  void close() {
    _closed = true;
    if (!_cancelled.isCompleted) _cancelled.complete(false);
  }

  /// Connects to the owner of parsed invitation [j], sends a [type] request
  /// and hands the owner's answer to [handle] while the connection is open.
  static Future<T> _send<T>(
    PeerNetwork network,
    Json j,
    String type,
    Future<T> Function(Json response, DeviceCertificate owner, Json card)
    handle,
  ) async {
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
          'type': type,
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
      return await handle(response, owner, card);
    } finally {
      connection.close();
      network._connections.remove(connection);
    }
  }
}

/// Only alive while the owner explicitly opens Add device. QUIC authenticates
/// the request device; the invitation pins the owner's endpoint and identity.
///
/// Any device holding the root can open one: [root] is the root unlocked with
/// the recovery phrase, held only while the session is open.
class PairingSession extends _InvitationSession {
  SimpleKeyPair? _root;

  /// Whether the new device also gets this device's sealed copy of the root,
  /// so that it too can add and remove devices. Read when approving.
  bool shareRoot = true;
  PairingSession(super.network, super.confirm, {SimpleKeyPair? root})
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
  @override
  String get _type => 'pairing';
  @override
  String get _noun => 'Pairing';

  static Json parse(String text) => _parseInvitation(
    text,
    'pairing',
    'Pairing',
    'Invalid or expired invitation. Open Add device again.',
  );

  static String code(String token, DeviceCertificate certificate) =>
      confirmationCode(token, certificate);

  @override
  Future<Json> _accept(String peer, Json card, DeviceCertificate cert) async {
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
  }

  @override
  void close() {
    _root = null;
    super.close();
  }

  static Future<LocalIdentity> join(
    PeerNetwork network,
    String invitation,
  ) async {
    if (network.node.store.count != 0)
      throw StateError('Use a fresh profile to connect');
    return _InvitationSession._send(network, parse(invitation), 'pair', (
      response,
      owner,
      card,
    ) async {
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
    });
  }
}
