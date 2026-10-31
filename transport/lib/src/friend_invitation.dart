part of 'network.dart';

/// Expiring single-use invitation. Does not enrol devices or share identity secrets.
class FriendSession extends _InvitationSession {
  String? acceptedPeer;
  FriendSession(super.network, super.confirm) {
    if (!network.running) {
      throw StateError('Connect before inviting a friend');
    }
    network.friendInvitation?.close();
    network.friendInvitation = this;
  }
  @override
  String get _type => 'friend';
  @override
  String get _noun => 'Friend';

  static Json parse(String text) => _parseInvitation(
    text,
    'friend',
    'Friend',
    'Invalid or expired invitation. Create a new friend invitation.',
  );

  static String code(String token, DeviceCertificate certificate) =>
      confirmationCode(token, certificate);

  @override
  Future<Json> _accept(String peer, Json card, DeviceCertificate cert) async {
    if (cert.person == network.node.person)
      throw StateError('Use Add device for your own profile.');
    if (!available) return {'error': 'Invitation cancelled'};
    await network.addCard(canonical(card));
    acceptedPeer = peer;
    _closed = true;
    return {'accepted': true, 'card': jsonDecode(network.contactCard())};
  }

  static Future<void> join(PeerNetwork network, String invitation) =>
      _InvitationSession._send(network, parse(invitation), 'friend', (
        response,
        owner,
        card,
      ) async {
        if (response['accepted'] != true)
          throw StateError('Invitation was not accepted.');
        final returned = DeviceCertificate.fromJson(
          (response['card'] as Json)['certificate'],
        );
        if (returned.device != owner.device || returned.person != owner.person)
          throw StateError('Unexpected friend identity');
        await network.addCard(canonical(card));
      });
}
