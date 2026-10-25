/// Remote desktop's native half (`rust/src/desktop.rs`): screen capture and
/// hardware H.264 on the receiving device, decoding into a texture on the
/// viewing one. Dart only moves bytes between these and the network; what
/// a session may do is decided by `ournet_core`'s plugins and the network.
/// See docs/REMOTE_DESKTOP.md.
@DefaultAsset('package:ournet_native/ournet_native.dart')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

@Native<Int32 Function()>(symbol: 'ournet_desktop_available', isLeaf: true)
external int _available();

@Native<Uint64 Function(Pointer<NativeFunction<_PostFunction>>, Pointer<Uint8>, Size)>(
  symbol: 'ournet_desktop_capture_start',
  isLeaf: true,
)
external int _captureStart(
  Pointer<NativeFunction<_PostFunction>> post,
  Pointer<Uint8> config,
  int length,
);

@Native<Int32 Function(Uint64, Pointer<Uint8>, Size)>(
  symbol: 'ournet_desktop_capture_datagram',
  isLeaf: true,
)
external int _captureDatagram(int handle, Pointer<Uint8> data, int length);

@Native<Int32 Function(Uint64)>(symbol: 'ournet_desktop_capture_stop', isLeaf: true)
external int _captureStop(int handle);

@Native<Uint64 Function()>(symbol: 'ournet_desktop_view_open', isLeaf: true)
external int _viewOpen();

@Native<Int32 Function(Uint64, Pointer<Uint8>, Size)>(
  symbol: 'ournet_desktop_view_push',
  isLeaf: true,
)
external int _viewPush(int handle, Pointer<Uint8> data, int length);

@Native<Int32 Function(Uint64, Pointer<Uint64>)>(
  symbol: 'ournet_desktop_view_status',
  isLeaf: true,
)
external int _viewStatus(int handle, Pointer<Uint64> out);

@Native<Size Function(Uint64, Pointer<Uint8>, Size)>(
  symbol: 'ournet_desktop_view_error',
  isLeaf: true,
)
external int _viewError(int handle, Pointer<Uint8> out, int capacity);

@Native<Int32 Function(Uint64)>(symbol: 'ournet_desktop_view_close', isLeaf: true)
external int _viewClose(int handle);

// Called by the Windows runner, not Dart: Dart hands it their addresses.
@Native<Int32 Function(Uint64, Pointer<Void>, Pointer<Void>)>(
  symbol: 'ournet_desktop_view_bind',
  isLeaf: true,
)
external int _viewBind(int handle, Pointer<Void> notify, Pointer<Void> context);

@Native<Pointer<Uint8> Function(Uint64, Pointer<Uint32>, Pointer<Uint32>)>(
  symbol: 'ournet_desktop_view_lock',
  isLeaf: true,
)
external Pointer<Uint8> _viewLock(
  int handle,
  Pointer<Uint32> width,
  Pointer<Uint32> height,
);

@Native<Void Function(Pointer<Uint8>, Size)>(symbol: 'ournet_free', isLeaf: true)
external void _free(Pointer<Uint8> data, int length);

typedef _PostFunction = Void Function(Uint64, Pointer<Uint8>, Size);

/// Stream frame types, as the capture posts them and the wire carries them:
/// `[type][u32 length][body]`.
abstract final class DesktopFrame {
  static const video = 1, info = 2, error = 3;
}

/// Datagram types from the viewer.
abstract final class DesktopDatagram {
  static const input = 1, ack = 2, keyframe = 3;
}

/// Whether this build can capture and view desktops.
final bool desktopAvailable = () {
  try {
    return _available() == 1;
  } catch (_) {
    return false;
  }
}();

/// One capture of this device's screen. Frames arrive on [onMessage]
/// already framed for the wire, on the event loop; an empty message means it
/// ended (after [stop], an error or the screen going away).
final class DesktopCapture {
  final int _handle;
  final NativeCallable<_PostFunction> _callback;
  bool _ended = false;

  DesktopCapture._(this._handle, this._callback);

  /// Null where capture is unavailable or [config] was refused. Config keys:
  /// `fps`, `kbps`, `width` (the widest stream), `display`, `inflight`.
  static DesktopCapture? start(
    Map<String, Object?> config,
    void Function(Uint8List message) onMessage,
  ) {
    if (!desktopAvailable) return null;
    late final DesktopCapture capture;
    final callback = NativeCallable<_PostFunction>.listener((
      int _,
      Pointer<Uint8> data,
      int length,
    ) {
      final message = length == 0
          ? Uint8List(0)
          : Uint8List.fromList(data.asTypedList(length));
      if (length > 0) _free(data, length);
      if (capture._ended) return;
      if (message.isEmpty) {
        capture._ended = true;
        capture._callback.close();
      }
      onMessage(message);
    });
    final c = Uint8List.fromList(utf8.encode(jsonEncode(config)));
    final handle = _captureStart(callback.nativeFunction, c.address, c.length);
    if (handle == 0) {
      callback.close();
      return null;
    }
    return capture = DesktopCapture._(handle, callback);
  }

  /// A datagram from the viewer: input, an ack or a keyframe request.
  bool datagram(Uint8List data) =>
      !_ended && _captureDatagram(_handle, data.address, data.length) == 1;

  /// Stops capturing; everything held on this device is released. The
  /// capture still posts its end.
  void stop() {
    if (!_ended) _captureStop(_handle);
  }
}

/// A decoder whose pictures a platform texture shows.
final class DesktopDecoder {
  final int handle;
  bool _closed = false;

  /// Whether [close] is this object's to do; see [handOver].
  bool _owned = true;

  DesktopDecoder._(this.handle);

  static DesktopDecoder? open() {
    if (!desktopAvailable) return null;
    final handle = _viewOpen();
    return handle == 0 ? null : DesktopDecoder._(handle);
  }

  /// Queues a video frame's body (`[u32 id][u64 µs][u8 flags][Annex B]`).
  /// False when it was dropped: the decoder has fallen behind and wants a
  /// keyframe.
  bool push(Uint8List body) =>
      !_closed && _viewPush(handle, body.address, body.length) == 1;

  /// Pictures decoded, their size, how long the last took, and whether a
  /// keyframe is wanted (reported once).
  ({int decoded, int width, int height, int decodeMicros, bool wantsKey})
  get status {
    final out = Uint64List(5);
    if (_closed || _viewStatus(handle, out.address) == 0) {
      return (decoded: 0, width: 0, height: 0, decodeMicros: 0, wantsKey: false);
    }
    return (
      decoded: out[0],
      width: out[1],
      height: out[2],
      decodeMicros: out[3],
      wantsKey: out[4] != 0,
    );
  }

  /// The decoder's last error, empty if none.
  String get error {
    if (_closed) return '';
    final out = Uint8List(512);
    final n = _viewError(handle, out.address, out.length);
    return utf8.decode(Uint8List.sublistView(out, 0, n), allowMalformed: true);
  }

  /// Closes the decoder: after this the handle names nothing.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_owned) _viewClose(handle);
  }

  /// Leaves closing the decoder to a texture, which does so through
  /// [closeAddress] once it has stopped reading it; [close] then only stops
  /// using it here.
  void handOver() => _owned = false;

  /// Where the runner's texture finds the decoder's functions.
  static int get bindAddress =>
      Native.addressOf<
            NativeFunction<Int32 Function(Uint64, Pointer<Void>, Pointer<Void>)>
          >(_viewBind)
          .address;
  static int get closeAddress =>
      Native.addressOf<NativeFunction<Int32 Function(Uint64)>>(
        _viewClose,
      ).address;
  static int get lockAddress =>
      Native.addressOf<
            NativeFunction<
              Pointer<Uint8> Function(Uint64, Pointer<Uint32>, Pointer<Uint32>)
            >
          >(_viewLock)
          .address;
}
