/// The native plugin host (`rust/src/plugin.rs`): WebAssembly components on
/// wasmtime, one thread each. This is the transport only; what calls mean,
/// and the answers to a plugin's imports, are decided by `ournet_core`'s
/// `Plugins`. See docs/PLUGINS.md.
@DefaultAsset('package:ournet_native/ournet_native.dart')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

@Native<Uint32 Function()>(symbol: 'ournet_plugins_init', isLeaf: true)
external int _init();

@Native<
  Uint64 Function(
    Pointer<NativeFunction<_PostFunction>>,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
  )
>(symbol: 'ournet_plugin_load', isLeaf: true)
external int _load(
  Pointer<NativeFunction<_PostFunction>> post,
  Pointer<Uint8> config,
  int configLength,
  Pointer<Uint8> wasm,
  int wasmLength,
);

@Native<Int32 Function(Uint64, Pointer<Uint8>, Size)>(
  symbol: 'ournet_plugin_call',
  isLeaf: true,
)
external int _call(int handle, Pointer<Uint8> message, int length);

@Native<Int32 Function(Uint64, Uint64, Pointer<Uint8>, Size)>(
  symbol: 'ournet_plugin_answer',
  isLeaf: true,
)
external int _answer(int handle, int id, Pointer<Uint8> message, int length);

@Native<Int32 Function(Uint64, Pointer<Uint8>, Size)>(
  symbol: 'ournet_plugin_reload',
  isLeaf: true,
)
external int _reload(int handle, Pointer<Uint8> wasm, int length);

@Native<Int32 Function(Uint64)>(symbol: 'ournet_plugin_stop', isLeaf: true)
external int _stop(int handle);

@Native<Void Function(Pointer<Uint8>, Size)>(
  symbol: 'ournet_free',
  isLeaf: true,
)
external void _free(Pointer<Uint8> data, int length);

typedef _PostFunction = Void Function(Uint64, Pointer<Uint8>, Size);

/// One message from a plugin's thread: a JSON header and the raw bytes that
/// followed it (a live message's payload), if any.
class PluginMessage {
  final Map<String, dynamic> header;
  final Uint8List body;
  PluginMessage(this.header, this.body);
  String get type => header['type'] as String? ?? '';

  static PluginMessage _parse(Uint8List bytes) {
    final newline = bytes.indexOf(0x0a);
    final head = newline < 0 ? bytes : Uint8List.sublistView(bytes, 0, newline);
    return PluginMessage(
      jsonDecode(utf8.decode(head)) as Map<String, dynamic>,
      newline < 0
          ? Uint8List(0)
          : Uint8List.fromList(Uint8List.sublistView(bytes, newline + 1)),
    );
  }
}

/// The plugin host, as this isolate sees it: messages for the plugins it
/// loaded arrive on its event loop, never synchronously. Other isolates have
/// their own.
final class PluginHost {
  /// Null where the native library or a code generator for this CPU is
  /// missing: plugins do not run there.
  static PluginHost? get instance => _instance ??= _start();
  static PluginHost? _instance;

  final NativeCallable<_PostFunction> _callback;
  final _listeners = <int, void Function(PluginMessage)>{};

  PluginHost._(this._callback);

  static PluginHost? _start() {
    late final PluginHost host;
    final callback = NativeCallable<_PostFunction>.listener((
      int handle,
      Pointer<Uint8> data,
      int length,
    ) {
      try {
        final message = PluginMessage._parse(data.asTypedList(length));
        host._listeners[handle]?.call(message);
      } catch (_) {
        // A malformed message from a plugin's thread is dropped.
      } finally {
        _free(data, length);
      }
    });
    try {
      if (_init() == 0) {
        callback.close();
        return null;
      }
    } catch (_) {
      // No native library on this platform.
      callback.close();
      return null;
    }
    return host = PluginHost._(callback);
  }

  /// Starts a plugin. It compiles on its own thread, then posts `loaded` or
  /// `failed` to [onMessage], followed by results, imports and notices.
  /// Returns its handle, or null when [config] was refused.
  int? load(
    Map<String, Object?> config,
    Uint8List wasm,
    void Function(PluginMessage) onMessage,
  ) {
    final c = Uint8List.fromList(utf8.encode(jsonEncode(config)));
    final handle = _load(
      _callback.nativeFunction,
      c.address,
      c.length,
      wasm.address,
      wasm.length,
    );
    if (handle == 0) return null;
    _listeners[handle] = onMessage;
    return handle;
  }

  /// Queues a call: a JSON header, and [body] bytes after it.
  bool call(int handle, Map<String, Object?> header, [Uint8List? body]) {
    final message = _frame(header, body);
    return _call(handle, message.address, message.length) == 1;
  }

  /// Answers the plugin's import [id]: `{"ok": …}` or `{"error": …}`.
  bool answer(int handle, int id, Map<String, Object?> answer) {
    final message = Uint8List.fromList(utf8.encode(jsonEncode(answer)));
    return _answer(handle, id, message.address, message.length) == 1;
  }

  /// Swaps in new code for a running plugin, keeping its state.
  bool reload(int handle, Uint8List wasm) =>
      _reload(handle, wasm.address, wasm.length) == 1;

  /// Stops a plugin; nothing more is delivered for it.
  void stop(int handle) {
    _listeners.remove(handle);
    _stop(handle);
  }

  static Uint8List _frame(Map<String, Object?> header, Uint8List? body) {
    final head = utf8.encode(jsonEncode(header));
    if (body == null) return Uint8List.fromList(head);
    return Uint8List(head.length + 1 + body.length)
      ..setRange(0, head.length, head)
      ..[head.length] = 0x0a
      ..setRange(head.length + 1, head.length + 1 + body.length, body);
  }
}
