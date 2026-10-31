import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:ournet_core/ournet_core.dart';

/// A running call shim: WebRTC on this device reaches the peer's by
/// sending to [address]:[port] (see [CallMediaNative]).
class CallShim {
  final InternetAddress address;
  final int port;
  const CallShim(this.address, this.port);

  /// The shim as a remote ICE candidate line, with the lowest priority so
  /// any path ICE finds itself is preferred.
  String get candidate =>
      'candidate:ournet 1 udp 1 ${address.address} $port typ host';
}

/// Call media over iroh in OurNet's iroh library (vendor/iroh_mobile,
/// `src/call_media.rs`): a UDP shim per call whose packets travel as QUIC
/// datagrams to the peer's shim. Plain C functions, like
/// [FriendRelayNative]. Null from [load] when the loaded library has none.
class CallMediaNative {
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, int)
  _start;
  final int Function(Pointer<Uint8>, Pointer<Uint8>) _stop;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, int) _stats;

  CallMediaNative._(DynamicLibrary lib)
    : _start = lib
          .lookupFunction<
            Int32 Function(
              Pointer<Uint8>,
              Pointer<Uint8>,
              Pointer<Uint8>,
              Size,
            ),
            int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, int)
          >('ournet_call_media_start'),
      _stop = lib
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Pointer<Uint8>),
            int Function(Pointer<Uint8>, Pointer<Uint8>)
          >('ournet_call_media_stop'),
      _stats = lib
          .lookupFunction<
            IntPtr Function(Pointer<Uint8>, Pointer<Uint8>, Size),
            int Function(Pointer<Uint8>, Pointer<Uint8>, int)
          >('ournet_call_media_stats');

  static CallMediaNative? load() {
    try {
      final lib = Platform.isIOS || Platform.isMacOS
          ? DynamicLibrary.process()
          : DynamicLibrary.open(
              Platform.isWindows ? 'irohdart_ffi.dll' : 'libirohdart_ffi.so',
            );
      if (!lib.providesSymbol('ournet_call_media_abi')) return null;
      final abi = lib
          .lookupFunction<Uint32 Function(), int Function()>(
            'ournet_call_media_abi',
          )
          .call();
      return abi == 1 ? CallMediaNative._(lib) : null;
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

  /// Starts [endpoint]'s shim for [peer] (32-byte ids) on [address], or
  /// rebinds a running one there. The port, or null.
  int? start(List<int> endpoint, List<int> peer, InternetAddress address) {
    final ip = utf8.encode(address.address);
    final port = _with(
      endpoint,
      (e) => _with(peer, (p) => _with(ip, (i) => _start(e, p, i, ip.length))),
    );
    return port > 0 ? port : null;
  }

  /// Stops the shim for [peer]; false when there was none.
  bool stop(List<int> endpoint, List<int> peer) =>
      _with(endpoint, (e) => _with(peer, (p) => _stop(e, p) == 0));

  /// The native counters (see `stats_json` in call_media.rs), or null.
  Json? stats(List<int> endpoint) => _with(endpoint, (e) {
    const capacity = 4 << 10;
    final out = calloc<Uint8>(capacity);
    try {
      final n = _stats(e, out, capacity);
      if (n < 0 || n > capacity) return null;
      return jsonDecode(utf8.decode(out.asTypedList(n))) as Json;
    } finally {
      calloc.free(out);
    }
  });

  /// The address a shim binds to: this device's own IPv4 address, not
  /// loopback, which libwebrtc never sends to. Null with no network.
  static Future<InternetAddress?> ownAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final i in interfaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback && !a.isLinkLocal) return a;
        }
      }
    } catch (_) {}
    return null;
  }
}
