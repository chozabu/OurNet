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

  /// Reads iroh's debug rendering of a transport address: `Relay(<url>)`
  /// or `Ip(<socket address>)`. Null for anything else.
  static PeerPath? parse(String remoteAddr, DateTime at) {
    final relay = RegExp(r'^Relay\((.+)\)$').firstMatch(remoteAddr);
    if (relay != null) return PeerPath(PathKind.relay, relay[1]!, at);
    final ip = RegExp(r'^Ip\((.+)\)$').firstMatch(remoteAddr);
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
