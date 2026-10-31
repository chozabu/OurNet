/// How a connection to a device reaches it, read from iroh's path events.
enum PathKind {
  /// Direct, to an address on a local network (private, link-local or
  /// loopback).
  lan,

  /// Direct, to a public address.
  direct,

  /// Through a relay server.
  relay,

  /// Through a mutual friend's device (docs/FRIEND_RELAY.md).
  friend,
}

/// The path a device was last reached over.
class PeerPath {
  final PathKind kind;

  /// The relay URL, the socket address, or for [PathKind.friend] the
  /// friend's endpoint id in hex.
  final String address;
  final DateTime at;

  /// For a direct path: the relay or friend the connection began on, which
  /// only helped the devices find each other.
  final PathKind? startedVia;
  const PeerPath(this.kind, this.address, this.at, {this.startedVia});

  /// This path, noting that the connection began on [first] when that was a
  /// relay or a friend and this one is direct.
  PeerPath after(PeerPath? first) =>
      isDirect && first != null && !first.isDirect
      ? PeerPath(kind, address, at, startedVia: first.kind)
      : this;

  bool get isDirect => kind != PathKind.relay && kind != PathKind.friend;

  /// Whether a direct path uses IPv6 (its socket address is bracketed).
  bool get isIpv6 => isDirect && address.startsWith('[');

  /// Reads iroh's debug rendering of a transport address: `Relay(<url>)`,
  /// `Ip(<socket address>)`, or a friend relay's custom address (transport
  /// id 0x4f4e4652, data the friend's id then the peer's; pinned by
  /// `debug_format_dart_parses` in friend_relay_tests.rs). Null for
  /// anything else.
  static final _relay = RegExp(r'^Relay\((.+)\)$'),
      _ip = RegExp(r'^Ip\((.+)\)$'),
      _friend = RegExp(
        r'^Custom\(CustomAddr \{ id: 1330529874, data: \[([0-9a-f]{64})[0-9a-f]{64}\] \}\)$',
      );

  static PeerPath? parse(String remoteAddr, DateTime at) {
    final relay = _relay.firstMatch(remoteAddr);
    if (relay != null) return PeerPath(PathKind.relay, relay[1]!, at);
    final friend = _friend.firstMatch(remoteAddr);
    if (friend != null) return PeerPath(PathKind.friend, friend[1]!, at);
    final ip = _ip.firstMatch(remoteAddr);
    if (ip == null) return null;
    final address = ip[1]!;
    return PeerPath(
      _local(address) ? PathKind.lan : PathKind.direct,
      address,
      at,
    );
  }

  /// Whether a socket address (`1.2.3.4:5` or `[fe80::1%3]:5`) is on a
  /// local network.
  static bool _local(String socket) {
    final host = socket.startsWith('[')
        ? socket.substring(1, socket.indexOf(']')).toLowerCase()
        : socket.substring(0, socket.lastIndexOf(':'));
    if (host.contains(':')) {
      return host == '::1' ||
          host.startsWith('fe80:') ||
          host.startsWith('fc') ||
          host.startsWith('fd');
    }
    final octets = host.split('.').map(int.tryParse).toList();
    if (octets.length != 4 || octets.contains(null)) return false;
    final a = octets[0]!, b = octets[1]!;
    return a == 10 ||
        a == 127 ||
        a == 192 && b == 168 ||
        a == 172 && b >= 16 && b <= 31 ||
        a == 169 && b == 254;
  }

  /// A short description for people, such as `direct on the local network`.
  String describe() => switch (kind) {
    PathKind.lan => 'direct on the local network$_helped',
    PathKind.direct => 'direct over the internet$_helped',
    PathKind.relay => 'through relay $relayName',
    PathKind.friend => 'through a friend\'s device',
  };

  /// The relay server's host name, for [PathKind.relay].
  String get relayName => Uri.tryParse(address)?.host ?? address;

  String get _helped => switch (startedVia) {
    PathKind.relay => ' (relay used to connect)',
    PathKind.friend => ' (friend used to connect)',
    _ => '',
  };

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'address': address,
    'at': at.toIso8601String(),
    if (startedVia != null) 'startedVia': startedVia!.name,
  };
}

/// Connections counted by the path each ended on, added to as they close
/// (never by scanning), for diagnostics: how often devices reach each other
/// directly, and how.
class PathCounts {
  int lan4 = 0, lan6 = 0, direct4 = 0, direct6 = 0, relay = 0, friend = 0;

  /// Connections whose path was never seen.
  int unknown = 0;

  /// Connections that began through a relay or a friend and ended direct.
  int upgraded = 0;

  int get total => lan4 + lan6 + direct4 + direct6 + relay + friend + unknown;

  /// Counts one connection that was first seen on [first] and ended on
  /// [last].
  void add(PeerPath? first, PeerPath? last) {
    switch (last?.kind) {
      case null:
        unknown++;
      case PathKind.relay:
        relay++;
      case PathKind.friend:
        friend++;
      case PathKind.lan:
        last!.isIpv6 ? lan6++ : lan4++;
      case PathKind.direct:
        last!.isIpv6 ? direct6++ : direct4++;
    }
    if (first != null && !first.isDirect && (last?.isDirect ?? false)) {
      upgraded++;
    }
  }

  Map<String, int> toJson() => {
    'total': total,
    'lan4': lan4,
    'lan6': lan6,
    'direct4': direct4,
    'direct6': direct6,
    'relay': relay,
    'friend': friend,
    'unknown': unknown,
    'upgraded': upgraded,
  };
}
