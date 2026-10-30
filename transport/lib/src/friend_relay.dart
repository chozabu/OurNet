import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';
import 'package:ournet_core/ournet_core.dart';

/// What decides whether this device relays for friends, besides the setting:
/// see [FriendRelayPolicy.decide]. Null means not known here.
class RelayConditions {
  /// On mains power (plugged in, for a laptop or phone).
  final bool? mains;

  /// Battery or data saver is on.
  final bool saver;

  /// The network is metered (mobile data, a hotspot, a capped plan).
  final bool? metered;

  /// Friends can reach this device directly. Null: judged from the
  /// endpoint's addresses (a public one counts).
  final bool? reachable;

  const RelayConditions({
    this.mains,
    this.saver = false,
    this.metered,
    this.reachable,
  });
}

/// Who relays, and through whom to try a device (docs/FRIEND_RELAY.md).
class FriendRelayPolicy {
  /// Listed in a device's capabilities while it relays for friends.
  static const cap = 'friend_relay';

  /// The setting: relay for friends. Unset means on for desktops and off
  /// for phones.
  static const setting = 'relayForFriends';

  /// Per-friend limits on what this device forwards.
  static const rate = 1 << 20; // bytes per second
  static const daily = 512 << 20; // bytes per day

  /// Friends offered per dial (the native side uses at most two).
  static const maxRoutes = 2;

  static bool get desktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Whether the setting is on, given its stored value.
  static bool enabled(Object? stored, {bool? isDesktop}) =>
      stored is bool ? stored : (isDesktop ?? desktop);

  /// Whether this device relays now, and if not, why not (for people).
  /// A desktop needs mains power; phones, opted in, may relay on battery.
  /// Neither relays on a metered network, with a saver on, or when friends
  /// cannot reach it directly.
  static ({bool relay, String reason}) decide({
    required bool enabled,
    required bool supported,
    required bool isDesktop,
    required RelayConditions conditions,
    required bool reachable,
  }) {
    if (!supported) {
      return (relay: false, reason: 'Not available in this build');
    }
    if (!enabled) return (relay: false, reason: 'Off');
    if (conditions.saver) {
      return (relay: false, reason: 'Paused: battery or data saver is on');
    }
    if (conditions.metered == true) {
      return (relay: false, reason: 'Paused: the network is metered');
    }
    if (isDesktop && conditions.mains == false) {
      return (relay: false, reason: 'Paused: running on battery');
    }
    if (!reachable) {
      return (
        relay: false,
        reason: 'Paused: friends cannot reach this device directly',
      );
    }
    return (relay: true, reason: 'Relaying for friends');
  }

  /// Whether a socket address (`1.2.3.4:5`, `[2001:db8::1]:5`) is public.
  static bool publicAddress(String socket) {
    final host = socket.startsWith('[')
        ? socket.substring(1, socket.indexOf(']')).toLowerCase()
        : socket.substring(0, socket.lastIndexOf(':'));
    return InternetAddressCheck.parse(host) == true;
  }

  /// The devices to offer as friend relays for reaching [device], best
  /// first: devices this one syncs with that listed [cap], that the target
  /// is known (or not known not) to be friends with, most recently synced
  /// first. A wrong guess costs one "no route" reply.
  static List<String> routes(
    Node node,
    String device, {
    required Map<String, Set<String>> peerCaps,
    required Map<String, DateTime> lastSync,
  }) {
    final target = node.contacts[device]?.person;
    if (target == null) return const [];
    final lists = node.connections.lists;
    bool knows(String person) {
      if (person == node.person || person == target) return true;
      if (target == node.person) return true;
      if (!lists.containsKey(person) && !lists.containsKey(target)) {
        return true;
      }
      return node.connections.friendsOf(person).contains(target) ||
          node.connections.friendsOf(target).contains(person);
    }

    final found = [
      for (final MapEntry(key: relay, value: caps) in peerCaps.entries)
        if (relay != device &&
            caps.contains(cap) &&
            node.allowedPeer(relay) &&
            knows(node.contacts[relay]!.person))
          relay,
    ];
    final never = DateTime.fromMillisecondsSinceEpoch(0);
    found.sort(
      (a, b) => (lastSync[b] ?? never).compareTo(lastSync[a] ?? never),
    );
    return found.take(maxRoutes).toList();
  }
}

/// Whether an IP address is public: not private, loopback, link-local,
/// unique-local or unspecified.
abstract final class InternetAddressCheck {
  /// True public, false not, null unparseable.
  static bool? parse(String host) {
    if (host.contains(':')) {
      final h = host.split('%').first;
      if (h == '::' || h == '::1') return false;
      if (h.startsWith('fe8') ||
          h.startsWith('fe9') ||
          h.startsWith('fea') ||
          h.startsWith('feb') ||
          h.startsWith('fc') ||
          h.startsWith('fd')) {
        return false;
      }
      if (h.startsWith('::ffff:')) return parse(h.substring(7));
      return true;
    }
    final octets = host.split('.').map(int.tryParse).toList();
    if (octets.length != 4 || octets.contains(null)) return null;
    final a = octets[0]!, b = octets[1]!;
    return !(a == 0 ||
        a == 10 ||
        a == 127 ||
        a == 100 && b >= 64 && b <= 127 ||
        a == 169 && b == 254 ||
        a == 172 && b >= 16 && b <= 31 ||
        a == 192 && b == 168 ||
        a >= 224);
  }
}

/// The friend relay controls in OurNet's iroh library (vendor/iroh_mobile,
/// `src/friend_relay.rs`): plain C functions, as iroh_quic's generated
/// bindings are upstream's. Null from [load] when the loaded library has
/// none (an upstream build, or one without the feature).
class FriendRelayNative {
  final int Function(Pointer<Uint8>, int, int, int) _policy;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, int) _allow;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, int)
  _routes;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, int) _stats;

  FriendRelayNative._(DynamicLibrary lib)
    : _policy = lib
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Uint32, Uint64, Uint64),
            int Function(Pointer<Uint8>, int, int, int)
          >('ournet_friend_relay_policy'),
      _allow = lib
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Size),
            int Function(Pointer<Uint8>, Pointer<Uint8>, int)
          >('ournet_friend_relay_allow'),
      _routes = lib
          .lookupFunction<
            Int32 Function(
              Pointer<Uint8>,
              Pointer<Uint8>,
              Pointer<Uint8>,
              Size,
            ),
            int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, int)
          >('ournet_friend_relay_routes'),
      _stats = lib
          .lookupFunction<
            IntPtr Function(Pointer<Uint8>, Pointer<Uint8>, Size),
            int Function(Pointer<Uint8>, Pointer<Uint8>, int)
          >('ournet_friend_relay_stats');

  static FriendRelayNative? load() {
    try {
      final lib = Platform.isIOS || Platform.isMacOS
          ? DynamicLibrary.process()
          : DynamicLibrary.open(
              Platform.isWindows ? 'irohdart_ffi.dll' : 'libirohdart_ffi.so',
            );
      if (!lib.providesSymbol('ournet_friend_relay_abi')) return null;
      final abi = lib
          .lookupFunction<Uint32 Function(), int Function()>(
            'ournet_friend_relay_abi',
          )
          .call();
      return abi == 1 ? FriendRelayNative._(lib) : null;
    } catch (_) {
      return null;
    }
  }

  static T _with<T>(List<int> bytes, T Function(Pointer<Uint8>) use) {
    final p = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      p.asTypedList(bytes.length).setAll(0, bytes);
      return use(p);
    } finally {
      calloc.free(p);
    }
  }

  static List<int> _join(Iterable<List<int>> ids) => [
    for (final id in ids)
      if (id.length == 32) ...id,
  ];

  /// Whether [endpoint] relays, and its per-sender limits (0 unlimited).
  bool policy(
    List<int> endpoint, {
    required bool relay,
    required int rate,
    required int daily,
  }) => _with(endpoint, (e) => _policy(e, relay ? 1 : 0, rate, daily) == 0);

  /// The devices that may link to [endpoint], and that it forwards between.
  bool allow(List<int> endpoint, Iterable<List<int>> devices) {
    final ids = _join(devices);
    return _with(
      endpoint,
      (e) => _with(ids, (p) => _allow(e, p, ids.length ~/ 32) == 0),
    );
  }

  /// The friends [endpoint] offers when dialling [peer].
  bool routes(List<int> endpoint, List<int> peer, Iterable<List<int>> relays) {
    final ids = _join(relays);
    return _with(
      endpoint,
      (e) => _with(
        peer,
        (p) => _with(ids, (r) => _routes(e, p, r, ids.length ~/ 32) == 0),
      ),
    );
  }

  /// The native counters (see `stats_json` in friend_relay.rs), or null.
  Json? stats(List<int> endpoint) => _with(endpoint, (e) {
    var capacity = 16 << 10;
    for (var attempt = 0; attempt < 3; attempt++) {
      final out = calloc<Uint8>(capacity);
      try {
        final n = _stats(e, out, capacity);
        if (n < 0) return null;
        if (n <= capacity) {
          return jsonDecode(utf8.decode(out.asTypedList(n))) as Json;
        }
        capacity = n;
      } finally {
        calloc.free(out);
      }
    }
    return null;
  });
}
