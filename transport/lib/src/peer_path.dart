/// How a connection to a device reaches it, read from iroh's path events.
enum PathKind {
  /// Direct, to an address on a local network (private, link-local or
  /// loopback).
  lan,

  /// Direct, to a public address.
  direct,

  /// Through a relay server.
  relay,
}

/// The path a device was last reached over.
class PeerPath {
  final PathKind kind;

  /// The relay URL or the socket address.
  final String address;
  final DateTime at;
  const PeerPath(this.kind, this.address, this.at);

  bool get isDirect => kind != PathKind.relay;

  /// Whether a direct path uses IPv6 (its socket address is bracketed).
  bool get isIpv6 => isDirect && address.startsWith('[');

  /// Reads iroh's debug rendering of a transport address: `Relay(<url>)`
  /// or `Ip(<socket address>)`. Null for anything else.
  static final _relay = RegExp(r'^Relay\((.+)\)$'), _ip = RegExp(r'^Ip\((.+)\)$');

  static PeerPath? parse(String remoteAddr, DateTime at) {
    final relay = _relay.firstMatch(remoteAddr);
    if (relay != null) return PeerPath(PathKind.relay, relay[1]!, at);
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
    PathKind.lan => 'direct on the local network',
    PathKind.direct => 'direct over the internet',
    PathKind.relay => 'through relay ${Uri.tryParse(address)?.host ?? address}',
  };

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'address': address,
    'at': at.toIso8601String(),
  };
}

/// Connections counted by the path each ended on, added to as they close
/// (never by scanning), for diagnostics: how often devices reach each other
/// directly, and how.
class PathCounts {
  int lan4 = 0, lan6 = 0, direct4 = 0, direct6 = 0, relay = 0;

  /// Connections whose path was never seen.
  int unknown = 0;

  /// Connections that began through a relay and ended direct.
  int upgraded = 0;

  int get total => lan4 + lan6 + direct4 + direct6 + relay + unknown;

  /// Counts one connection that was first seen on [first] and ended on
  /// [last].
  void add(PeerPath? first, PeerPath? last) {
    switch (last?.kind) {
      case null:
        unknown++;
      case PathKind.relay:
        relay++;
      case PathKind.lan:
        last!.isIpv6 ? lan6++ : lan4++;
      case PathKind.direct:
        last!.isIpv6 ? direct6++ : direct4++;
    }
    if (first?.kind == PathKind.relay && (last?.isDirect ?? false)) upgraded++;
  }

  Map<String, int> toJson() => {
    'total': total,
    'lan4': lan4,
    'lan6': lan6,
    'direct4': direct4,
    'direct6': direct6,
    'relay': relay,
    'unknown': unknown,
    'upgraded': upgraded,
  };
}
