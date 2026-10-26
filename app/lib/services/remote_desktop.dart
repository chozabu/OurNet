import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show BytesBuilder;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// Remote desktop between this person's own devices (docs/REMOTE_DESKTOP.md):
/// serves this device's screen to devices a plugin admitted, and runs the
/// views plugins open. Video and input go straight between the native code
/// and the network; the plugin only decides who and when.
class RemoteDesktops {
  RemoteDesktops(this.network, this.plugins) {
    network.serveDesktop = _serve;
    plugins
      ..openDesktop = open
      ..closeDesktop = close
      ..stopDesktops = stopServing;
    instance = this;
  }

  /// The app's, for `DesktopView` widgets to find their sessions.
  static RemoteDesktops? instance;

  final PeerNetwork network;
  final Plugins plugins;
  final _views = <String, DesktopSession>{};
  final _serving = <String, Set<DesktopCapture>>{};
  final _random = Random.secure();

  /// Views open at once; each holds a decoder and a texture.
  static const maxViews = 4;

  /// Without a datagram from the viewer for this long (it sends its input
  /// state every second at least), the stream ends.
  static const viewerSilence = Duration(seconds: 6);

  DesktopSession? session(String id) => _views[id];

  /// Opens a view of [device] for [plugin]; see [Plugins.openDesktop].
  String open(String plugin, String device, Json options) {
    final preview = device == network.node.identity.device;
    if (preview && !(desktopAvailable && Platform.isWindows)) {
      throw StateError('Previewing this screen needs Windows for now');
    }
    if (!Platform.isAndroid && !(desktopAvailable && Platform.isWindows)) {
      throw StateError('Viewing a desktop needs Windows or Android for now');
    }
    if (_views.length >= maxViews) {
      // The oldest goes: a plugin that forgot to close its views.
      close(_views.keys.first);
    }
    final id = [
      for (var i = 0; i < 8; i++) _random.nextInt(256).toRadixString(16),
    ].join();
    final session = _views[id] = DesktopSession._(
      id,
      plugin,
      device,
      plugins.deviceName(device),
      options,
      network,
    );
    unawaited(session._run());
    return id;
  }

  void close(String id) => _views.remove(id)?._close();

  /// Ends the streams this device serves for [plugin].
  void stopServing(String plugin) {
    for (final capture in _serving.remove(plugin) ?? const <DesktopCapture>{}) {
      capture.stop();
    }
  }

  void dispose() {
    for (final id in _views.keys.toList()) {
      close(id);
    }
    for (final plugin in _serving.keys.toList()) {
      stopServing(plugin);
    }
    if (identical(instance, this)) instance = null;
    if (network.serveDesktop == _serve) network.serveDesktop = null;
  }

  static int _bounded(Object? v, int low, int high, int fallback) =>
      v is num ? v.toInt().clamp(low, high) : fallback;

  Future<void> _serve(String peer, Json request, DesktopServing stream) async {
    final plugin = '${request['plugin']}';
    if (!plugins.admitDesktop(peer, plugin)) {
      throw StateError('Not allowed: allow remote desktop on that device');
    }
    if (!desktopAvailable || !Platform.isWindows) {
      throw StateError('This device cannot share its screen yet');
    }
    final ended = Completer<void>();
    String? error;
    final capture = DesktopCapture.start(
      {
        'fps': _bounded(request['fps'], 1, 240, 60),
        'kbps': _bounded(request['kbps'], 500, 200000, 20000),
        'width': _bounded(request['width'], 320, 7680, 1920),
        'display': _bounded(request['display'], 0, 15, 0),
        'inflight': _bounded(request['inflight'], 1, 8, 2),
        'audio': request['audio'] != false,
        // Clipboard text only ever goes between this person's own devices.
        'clipboard': request['clipboard'] == true && plugins.ownDevice(peer),
      },
      (message) {
        if (message.isEmpty) {
          if (!ended.isCompleted) ended.complete();
          return;
        }
        if (message[0] == DesktopFrame.error) {
          error = utf8.decode(message.sublist(5), allowMalformed: true);
        }
        unawaited(stream.write(message));
      },
    );
    if (capture == null) throw StateError('Screen capture is unavailable');
    (_serving[plugin] ??= {}).add(capture);
    var heard = DateTime.now();
    StreamSubscription<Uint8List>? datagrams, controls;
    Timer? watch;
    try {
      await stream.accept({'v': 1});
      plugins.desktopServing(plugin, peer);
      datagrams = stream.datagrams.listen((data) {
        heard = DateTime.now();
        capture.datagram(data);
      });
      controls = stream.controls.listen(capture.control);
      watch = Timer.periodic(const Duration(seconds: 1), (_) {
        final silent = DateTime.now().difference(heard) > viewerSilence;
        if (silent || !network.node.allowedPeer(peer)) {
          capture.stop();
        } else {
          plugins.desktopServing(plugin, peer);
        }
      });
      await Future.any([ended.future, stream.done]);
    } finally {
      watch?.cancel();
      capture.stop();
      await ended.future.timeout(const Duration(seconds: 3), onTimeout: () {});
      unawaited(datagrams?.cancel());
      unawaited(controls?.cancel());
      _serving[plugin]?.remove(capture);
      if (error != null) debugPrint('Desktop capture for $peer: $error');
    }
  }
}

enum DesktopState { connecting, streaming, ended, failed }

/// One view of another device's desktop: its connection, decoder, texture
/// and the input sent back. Widgets listen to it for state and figures.
class DesktopSession extends ChangeNotifier {
  DesktopSession._(
    this.id,
    this.plugin,
    this.device,
    this.deviceName,
    this.options,
    this._network,
  ) : preview = device == _network.node.identity.device;

  static const _channel = MethodChannel('ournet/desktop');

  final String id, plugin, device, deviceName;
  final Json options;

  /// This device's own screen: the same capture, encoder and decoder, with
  /// no network and no control.
  final bool preview;
  final PeerNetwork _network;

  DesktopState state = DesktopState.connecting;
  String error = '';

  /// What the served side last reported: `width`, `height`, `encoder`,
  /// `hardware`, `fps`, `kbps`, `latency` (ms, capture to ack), …
  Json info = const {};

  /// The Flutter texture showing the decoded picture, once there is one.
  int? textureId;
  int decodeMicros = 0;
  int framesReceived = 0;

  /// Pictures the decoder has produced.
  int decoded = 0;

  /// The other device's pointer: its shape (with hot spot, in source
  /// pixels) and where it is. Separate from the rest so moving it redraws
  /// only the pointer.
  final cursor = ValueNotifier<DesktopCursor?>(null);

  /// Whether its sound plays here.
  bool sound = true;

  /// Pointer lock: movement goes as relative counts (games).
  bool locked = false;

  DesktopDecoder? _decoder;
  int? _texture;
  DesktopViewing? _link;
  DesktopCapture? _capture;
  Timer? _tick;
  bool _closed = false;

  // Input, as state: see `InputState` in native/rust/src/desktop.rs.
  int _seq = 0, _x = 0, _y = 0, _buttons = 0, _wheel = 0, _hwheel = 0;
  int _relX = 0, _relY = 0, _repeats = 0, _repeatKey = 0;
  final _keys = <int>{};
  DateTime _sent = DateTime.fromMillisecondsSinceEpoch(0);

  static const maxKeys = 16;

  /// Android decodes with MediaCodec straight into its texture
  /// (`DesktopDecoder.kt`); Windows with the native decoder, which the
  /// runner's texture reads.
  static bool get _platformDecoder => Platform.isAndroid;

  Future<void> _run() async {
    try {
      final Map<String, Object?>? texture;
      if (_platformDecoder) {
        texture = await _channel.invokeMapMethod<String, Object?>('create');
      } else {
        final decoder = _decoder = DesktopDecoder.open();
        if (decoder == null) throw StateError('No decoder on this device');
        texture = await _channel.invokeMapMethod<String, Object?>('create', {
          'view': decoder.handle,
          'bind': DesktopDecoder.bindAddress,
          'lock': DesktopDecoder.lockAddress,
          'close': DesktopDecoder.closeAddress,
        });
        // The texture closes the decoder once Flutter has let it go.
        decoder.handOver();
      }
      _texture = texture?['handle'] as int?;
      textureId = texture?['texture'] as int?;
      if (_closed) {
        _disposeTexture();
        return;
      }
      final request = {
        for (final key in const ['fps', 'kbps', 'width', 'display'])
          if (options[key] is num) key: options[key],
        'audio': options['audio'] != false && !preview,
        'clipboard': options['clipboard'] != false && !preview,
      };
      final Stream<(int, Uint8List)> frames;
      if (preview) {
        frames = _localFrames(request);
      } else {
        final link = _link = await _network.openDesktop(device, {
          'plugin': plugin,
          ...request,
        });
        if (_closed) {
          link.close();
          return;
        }
        frames = link.frames;
      }
      state = DesktopState.streaming;
      notifyListeners();
      _tick = Timer.periodic(const Duration(milliseconds: 100), (_) => _beat());
      await for (final (type, body) in frames) {
        if (_closed) break;
        switch (type) {
          case DesktopFrame.video when body.length >= 13:
            framesReceived++;
            _push(body);
            // Acknowledged on arrival: the served side keeps at most a few
            // frames on the way, so a slow link never queues latency.
            _datagram([DesktopDatagram.ack, ...body.sublist(0, 4)]);
          case DesktopFrame.info:
            final j = jsonDecode(utf8.decode(body));
            if (j is Map && j['retrying'] == null) {
              info = {...info, ...j.cast<String, Object?>()};
              _resize();
              notifyListeners();
            }
          case DesktopFrame.error:
            final j = jsonDecode(utf8.decode(body));
            error = j is Map ? '${j['error']}' : '$j';
          case DesktopFrame.cursorShape when body.length >= 8:
            unawaited(_shape(body));
          case DesktopFrame.cursorAt when body.length >= 9:
            final d = ByteData.sublistView(body);
            cursor.value = (cursor.value ?? const DesktopCursor()).at(
              d.getInt32(0, Endian.little),
              d.getInt32(4, Endian.little),
              body[8] != 0,
            );
          case DesktopFrame.clipboard:
            final text = utf8.decode(body, allowMalformed: true);
            _remoteClipboard = text;
            _localClipboard = text;
            unawaited(Clipboard.setData(ClipboardData(text: text)));
          case DesktopFrame.audio when body.length > 5:
            if (sound) _audio(body);
        }
      }
      if (!_closed) {
        state = error.isEmpty ? DesktopState.ended : DesktopState.failed;
        if (error.isEmpty) error = 'The other device ended the session';
      }
    } catch (e) {
      if (_closed) return;
      state = DesktopState.failed;
      error = e is StateError ? e.message : '$e';
    } finally {
      _tick?.cancel();
      if (!_closed) notifyListeners();
    }
  }

  void _keyframe() => _datagram([DesktopDatagram.keyframe]);

  Future<void> _shape(Uint8List body) async {
    final d = ByteData.sublistView(body);
    final w = d.getUint16(0, Endian.little), h = d.getUint16(2, Endian.little);
    if (w == 0 || h == 0 || body.length < 8 + w * h * 4) return;
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      Uint8List.sublistView(body, 8, 8 + w * h * 4),
      w,
      h,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    final image = await done.future;
    if (_closed) return;
    cursor.value = (cursor.value ?? const DesktopCursor()).shaped(
      image,
      d.getInt16(4, Endian.little),
      d.getInt16(6, Endian.little),
    );
  }

  final _pending = BytesBuilder(copy: false);
  int _pendingRate = 0, _pendingChannels = 0;

  /// Plays a sound chunk: on Windows through the native player, on Android
  /// gathered into 20 ms for the platform's.
  void _audio(Uint8List body) {
    if (!_platformDecoder) {
      _decoder?.audio(body);
      return;
    }
    final handle = _texture;
    if (handle == null) return;
    final d = ByteData.sublistView(body);
    final rate = d.getUint32(0, Endian.little), channels = body[4];
    if (rate != _pendingRate || channels != _pendingChannels) {
      _pending.clear();
      _pendingRate = rate;
      _pendingChannels = channels;
    }
    _pending.add(Uint8List.sublistView(body, 5));
    if (_pending.length < rate * channels * 2 ~/ 50) return;
    unawaited(
      _channel
          .invokeMethod<void>('audio', {
            'handle': handle,
            'rate': rate,
            'channels': channels,
            'data': _pending.takeBytes(),
          })
          .catchError((Object _) {}),
    );
  }

  /// Turns sound here on or off.
  void setSound(bool on) {
    sound = on;
    notifyListeners();
  }

  // Clipboard text last seen on each side, so a copy is not sent back.
  String? _remoteClipboard, _localClipboard;
  int _beats = 0;

  /// On desktop, this device's clipboard follows to the other as it
  /// changes (checked each second while the view is open). A phone sends
  /// it only when asked ([sendClipboard]): reading its clipboard unasked
  /// would tell the person each time.
  Future<void> _watchClipboard() async {
    if (Platform.isAndroid || info['clipboard'] != true) return;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text == _localClipboard) return;
    _localClipboard = text;
    if (text != _remoteClipboard) _sendClipboardText(text);
  }

  /// Sends this device's clipboard text to the other device.
  Future<bool> sendClipboard() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty || info['clipboard'] != true) return false;
    _localClipboard = text;
    _sendClipboardText(text);
    return true;
  }

  void _sendClipboardText(String text) {
    final bytes = utf8.encode(text);
    if (bytes.length > 256 * 1024) return;
    _remoteClipboard = text;
    unawaited(_link?.control(DesktopControl.clipboard, bytes));
  }

  /// Text typed here (a phone's keyboard), entered there as typed.
  void text(String text) {
    if (text.isEmpty) return;
    unawaited(_link?.control(DesktopControl.text, utf8.encode(text)));
  }

  /// A key pressed and released there, by USB HID usage.
  void tap(int usage) => unawaited(
    _link?.control(DesktopControl.tap, [usage & 0xff, (usage >> 8) & 0xff]),
  );

  /// Shows output [index] of the other device.
  void selectDisplay(int index) {
    unawaited(_link?.control(DesktopControl.display, [index]));
    info = {...info, 'display': index};
    notifyListeners();
  }

  /// Relative movement while the pointer is locked, in mouse counts.
  void relative(int dx, int dy) {
    if (dx == 0 && dy == 0) return;
    _relX = (_relX + dx).toSigned(32);
    _relY = (_relY + dy).toSigned(32);
    _sendInput();
  }

  /// The keyboard here repeated a held key.
  void repeat(int usage) {
    if (!_keys.contains(usage)) return;
    _repeats = (_repeats + 1) & 0xffffffff;
    _repeatKey = usage;
    _sendInput();
  }

  void setLocked(bool on) {
    if (locked == on) return;
    locked = on;
    notifyListeners();
  }

  /// Hands a video frame's body to the decoder.
  void _push(Uint8List body) {
    if (!_platformDecoder) {
      if (_decoder?.push(body) == false) _keyframe();
      return;
    }
    final handle = _texture;
    if (handle == null) return;
    unawaited(
      _channel
          .invokeMethod<bool>('frame', {
            'handle': handle,
            'key': body[12] & 1 != 0,
            'data': Uint8List.sublistView(body, 13),
          })
          .then((queued) {
            if (queued == false) _keyframe();
          }, onError: (Object _) {}),
    );
  }

  (int, int)? _size;

  /// Tells a platform decoder the stream's size, which it needs to start.
  void _resize() {
    final w = info['width'], h = info['height'], handle = _texture;
    if (!_platformDecoder || w is! num || h is! num || handle == null) return;
    if (_size == (w.toInt(), h.toInt())) return;
    _size = (w.toInt(), h.toInt());
    unawaited(
      _channel
          .invokeMethod<void>('size', {
            'handle': handle,
            'width': w.toInt(),
            'height': h.toInt(),
          })
          .catchError((Object _) {}),
    );
  }

  bool _asking = false;

  /// A platform decoder's figures, one question at a time.
  Future<void> _platformStatus() async {
    final handle = _texture;
    if (_asking || handle == null) return;
    _asking = true;
    try {
      final s = await _channel.invokeMapMethod<String, Object?>('status', {
        'handle': handle,
      });
      if (s == null || _closed) return;
      if (s['wantsKey'] == true) _keyframe();
      decoded = (s['decoded'] as num?)?.toInt() ?? decoded;
      decodeMicros = (s['decodeMicros'] as num?)?.toInt() ?? decodeMicros;
    } catch (_) {
      // Gone with the view.
    } finally {
      _asking = false;
    }
  }

  void _datagram(List<int> data) {
    _link?.datagram(data);
    _capture?.datagram(Uint8List.fromList(data));
  }

  /// This device's own screen, captured here and never sent anywhere.
  Stream<(int, Uint8List)> _localFrames(Json config) {
    late final StreamController<(int, Uint8List)> frames;
    frames = StreamController(
      onListen: () {
        _capture = DesktopCapture.start(config, (message) {
          if (message.isEmpty) {
            unawaited(frames.close());
          } else if (message.length >= 5) {
            frames.add((message[0], Uint8List.sublistView(message, 5)));
          }
        });
        if (_capture == null) {
          frames.addError(StateError('Screen capture is unavailable'));
          unawaited(frames.close());
        }
      },
      onCancel: () => _capture?.stop(),
    );
    return frames.stream;
  }

  void _beat() {
    if (_platformDecoder) unawaited(_platformStatus());
    if (++_beats % 10 == 0) unawaited(_watchClipboard());
    final status = _decoder?.status;
    if (status != null) {
      if (status.wantsKey) _keyframe();
      decoded = status.decoded;
      if (status.decodeMicros != decodeMicros) {
        decodeMicros = status.decodeMicros;
      }
    }
    // The state again: every 100 ms while anything is held, so nothing
    // sticks if one is lost, and every second otherwise, as a keepalive.
    final holding = _buttons != 0 || _keys.isNotEmpty;
    final wait = holding
        ? const Duration(milliseconds: 100)
        : const Duration(seconds: 1);
    if (DateTime.now().difference(_sent) >= wait) _sendInput();
  }

  void _sendInput() {
    final link = _link;
    // A preview never controls: it would chase its own pointer.
    if (link == null || state != DesktopState.streaming) return;
    _seq = (_seq + 1) & 0xffffffff;
    final keys = _keys.take(maxKeys).toList();
    final data = ByteData(33 + 2 * keys.length)
      ..setUint8(0, DesktopDatagram.input2)
      ..setUint32(1, _seq, Endian.little)
      ..setUint16(5, _x, Endian.little)
      ..setUint16(7, _y, Endian.little)
      ..setUint8(9, _buttons)
      ..setInt32(10, _wheel, Endian.little)
      ..setInt32(14, _hwheel, Endian.little)
      ..setInt32(18, _relX, Endian.little)
      ..setInt32(22, _relY, Endian.little)
      ..setUint32(26, _repeats, Endian.little)
      ..setUint16(30, _repeatKey, Endian.little)
      ..setUint8(32, keys.length);
    for (var i = 0; i < keys.length; i++) {
      data.setUint16(33 + 2 * i, keys[i], Endian.little);
    }
    link.datagram(data.buffer.asUint8List());
    _sent = DateTime.now();
  }

  /// The pointer over the remote output, 0–1 each way. Ignored while the
  /// pointer is locked, when only relative movement counts.
  void pointer(double x, double y) {
    if (locked) return;
    final nx = (x.clamp(0.0, 1.0) * 65535).round();
    final ny = (y.clamp(0.0, 1.0) * 65535).round();
    if (nx == _x && ny == _y) return;
    _x = nx;
    _y = ny;
    _sendInput();
  }

  /// Held mouse buttons: left 1, right 2, middle 4, back 8, forward 16.
  void buttons(int mask) {
    if (mask & 0x1f == _buttons) return;
    _buttons = mask & 0x1f;
    _sendInput();
  }

  /// Scrolls by [notches] (positive away from the person, as Windows
  /// counts), horizontally when [horizontal].
  void wheel(double notches, {bool horizontal = false}) {
    final units = (notches * 120).round();
    if (units == 0) return;
    if (horizontal) {
      _hwheel = (_hwheel + units).toSigned(32);
    } else {
      _wheel = (_wheel + units).toSigned(32);
    }
    _sendInput();
  }

  /// A key by USB HID usage (page 7), down or up.
  void key(int usage, bool down) {
    final changed = down
        ? (_keys.length < maxKeys && _keys.add(usage))
        : _keys.remove(usage);
    if (changed) _sendInput();
  }

  /// Lets go of every key and button: when the view loses focus.
  void releaseAll() {
    if (_keys.isEmpty && _buttons == 0) return;
    _keys.clear();
    _buttons = 0;
    _sendInput();
  }

  void _close() {
    if (_closed) return;
    releaseAll();
    _closed = true;
    _tick?.cancel();
    _link?.close();
    _capture?.stop();
    _disposeTexture();
    // Closes it unless a texture holds it, which closes it itself.
    _decoder?.close();
    state = DesktopState.ended;
    notifyListeners();
    cursor.value?.image?.dispose();
    cursor.value = null;
  }

  void _disposeTexture() {
    final handle = _texture;
    _texture = null;
    textureId = null;
    if (handle == null) return;
    unawaited(
      _channel
          .invokeMethod<void>('dispose', {'handle': handle})
          .catchError((Object _) {}),
    );
  }
}

/// The other device's pointer, as `DesktopView` draws it.
@immutable
class DesktopCursor {
  final ui.Image? image;
  final int hotX, hotY;

  /// The shape's top left, in the source's pixels.
  final int x, y;
  final bool visible;

  const DesktopCursor({
    this.image,
    this.hotX = 0,
    this.hotY = 0,
    this.x = 0,
    this.y = 0,
    this.visible = false,
  });

  DesktopCursor at(int x, int y, bool visible) => DesktopCursor(
    image: image,
    hotX: hotX,
    hotY: hotY,
    x: x,
    y: y,
    visible: visible,
  );

  DesktopCursor shaped(ui.Image image, int hotX, int hotY) {
    this.image?.dispose();
    return DesktopCursor(
      image: image,
      hotX: hotX,
      hotY: hotY,
      x: x,
      y: y,
      visible: visible,
    );
  }
}
