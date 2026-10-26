import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/remote_desktop.dart';

/// Another device's desktop: the decoded stream as a texture, with this
/// device's mouse, touch and keyboard sent back while it is focused (click
/// or tap it). Plugins show it as `DesktopView` with the `session` their
/// `remote-desktop.view` returned. See docs/REMOTE_DESKTOP.md.
///
/// With a mouse, the pointer goes where it points; Ctrl+Alt+Shift+L locks
/// it for games (relative movement), Ctrl+Alt+Shift+F toggles the full
/// view. With touch, a tap clicks, a held finger right-clicks, a moved
/// finger drags, two fingers scroll, and a two-finger tap right-clicks.
class DesktopView extends StatefulWidget {
  final String session;

  /// Fills its space edge to edge, for the full view.
  final bool full;
  final bool showStats;

  const DesktopView({
    super.key,
    required this.session,
    this.full = false,
    this.showStats = true,
  });

  @override
  State<DesktopView> createState() => _DesktopViewState();
}

/// The Windows runner's pointer lock (`windows/runner/pointer_lock.cpp`).
abstract final class _PointerLock {
  static const _channel = MethodChannel('ournet/pointer');
  static void Function(int dx, int dy)? onMoved;
  static void Function()? onUnlocked;
  static bool _listening = false;

  static bool get supported => Platform.isWindows;

  static Future<bool> lock() async {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'moved' && call.arguments is List) {
          final [dx, dy] = call.arguments as List;
          onMoved?.call(dx as int, dy as int);
        } else if (call.method == 'unlocked') {
          onUnlocked?.call();
        }
      });
    }
    return await _channel.invokeMethod<bool>('lock') ?? false;
  }

  static Future<void> unlock() =>
      _channel.invokeMethod<void>('unlock').catchError((Object _) {});
}

class _DesktopViewState extends State<DesktopView> {
  final _focus = FocusNode(debugLabel: 'Remote desktop');
  final _typing = FocusNode(debugLabel: 'Remote desktop keyboard');
  final _typed = TextEditingController(text: _sentinel);
  DesktopSession? _session;
  bool _focused = false;
  bool _stats = true;

  /// Flutter's scroll delta for one wheel notch on Windows.
  static const _pixelsPerNotch = 20.0;

  /// Two-finger travel for one notch of scrolling.
  static const _touchPerNotch = 40.0;

  /// What the hidden text field holds, so deleting is seen as Backspace.
  static const _sentinel = '  ';

  @override
  void initState() {
    super.initState();
    _attach();
    if (widget.full) _focus.requestFocus();
  }

  @override
  void didUpdateWidget(DesktopView old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) _attach();
  }

  void _attach() {
    _session?.removeListener(_changed);
    _session = RemoteDesktops.instance?.session(widget.session);
    _session?.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _touchTimer?.cancel();
    if (_session?.locked == true) unawaited(_unlock());
    _session?.releaseAll();
    _session?.removeListener(_changed);
    _focus.dispose();
    _typing.dispose();
    _typed.dispose();
    super.dispose();
  }

  // ── mouse ──

  void _pointer(PointerEvent event, Size size) {
    final s = _session;
    if (s == null || size.isEmpty) return;
    if (event.kind == PointerDeviceKind.touch) return;
    s.pointer(
      event.localPosition.dx / size.width,
      event.localPosition.dy / size.height,
    );
    s.buttons(event.buttons);
  }

  // ── touch ──

  final _touches = <int, Offset>{};
  Offset? _touchStart;
  bool _dragging = false, _scrolled = false, _twoFingers = false;
  bool _consumed = false;
  Timer? _touchTimer;
  double _scrollCarry = 0;

  void _place(Offset at, Size size) =>
      _session?.pointer(at.dx / size.width, at.dy / size.height);

  Future<void> _click(int button) async {
    final s = _session;
    if (s == null) return;
    s.buttons(button);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    s.buttons(0);
  }

  void _touchDown(PointerDownEvent e, Size size) {
    _touches[e.pointer] = e.localPosition;
    if (_touches.length == 1) {
      _touchStart = e.localPosition;
      _dragging = _scrolled = _twoFingers = _consumed = false;
      _scrollCarry = 0;
      _place(e.localPosition, size);
      _touchTimer?.cancel();
      // A finger held still is a right-click.
      _touchTimer = Timer(const Duration(milliseconds: 550), () {
        if (_touches.length == 1 && !_dragging && !_consumed) {
          _consumed = true;
          unawaited(HapticFeedback.mediumImpact());
          unawaited(_click(2));
        }
      });
    } else {
      _touchTimer?.cancel();
      _twoFingers = true;
      if (_dragging) {
        _session?.buttons(0);
        _dragging = false;
      }
    }
  }

  void _touchMove(PointerMoveEvent e, Size size) {
    final before = _touches[e.pointer];
    if (before == null) return;
    _touches[e.pointer] = e.localPosition;
    if (_touches.length >= 2) {
      // Two fingers: scroll by their average travel.
      _scrollCarry += e.delta.dy / _touches.length;
      final notches = (_scrollCarry / _touchPerNotch).truncateToDouble();
      if (notches != 0) {
        _scrollCarry -= notches * _touchPerNotch;
        _scrolled = true;
        _session?.wheel(notches);
      }
      return;
    }
    if (_twoFingers || _consumed) return;
    final start = _touchStart ?? e.localPosition;
    if (!_dragging && (e.localPosition - start).distance > 10) {
      _dragging = true;
      _touchTimer?.cancel();
      _session?.buttons(1);
    }
    _place(e.localPosition, size);
  }

  void _touchUp(PointerEvent e) {
    if (_touches.remove(e.pointer) == null) return;
    if (_touches.isNotEmpty) return;
    _touchTimer?.cancel();
    if (_dragging) {
      _session?.buttons(0);
    } else if (_twoFingers && !_scrolled) {
      unawaited(_click(2));
    } else if (!_twoFingers && !_consumed) {
      unawaited(_click(1));
    }
    _dragging = false;
  }

  // ── keyboard ──

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    final s = _session;
    // The phone's keyboard types through its text field instead.
    if (s == null || _typing.hasFocus) return KeyEventResult.ignored;
    // Ctrl+Alt+Shift+F toggles the full view and +L the pointer lock;
    // every other key goes to the other device, so its shortcuts work and
    // ours do not fire.
    final keys = HardwareKeyboard.instance;
    final chord =
        keys.isControlPressed && keys.isAltPressed && keys.isShiftPressed;
    if (event is KeyDownEvent && chord) {
      if (event.logicalKey == LogicalKeyboardKey.keyF) {
        s.releaseAll();
        _toggleFull();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyL) {
        s.releaseAll();
        unawaited(s.locked ? _unlock() : _lock());
        return KeyEventResult.handled;
      }
    }
    final usage = event.physicalKey.usbHidUsage;
    if (usage >> 16 != 0x07) return KeyEventResult.handled;
    switch (event) {
      case KeyDownEvent():
        s.key(usage & 0xffff, true);
      case KeyRepeatEvent():
        s.repeat(usage & 0xffff);
      case KeyUpEvent():
        s.key(usage & 0xffff, false);
    }
    return KeyEventResult.handled;
  }

  /// The phone's keyboard: what is typed goes as text, deleting as
  /// Backspace, a new line as Enter.
  void _softTyped(String value) {
    final s = _session;
    if (s == null) return;
    if (value.length < _sentinel.length) {
      for (var i = value.length; i < _sentinel.length; i++) {
        s.tap(0x2a);
      }
    } else if (value.length > _sentinel.length) {
      final typed = value.substring(_sentinel.length);
      final lines = typed.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (i > 0) s.tap(0x28);
        s.text(lines[i]);
      }
    }
    _typed.value = const TextEditingValue(
      text: _sentinel,
      selection: TextSelection.collapsed(offset: _sentinel.length),
    );
  }

  void _toggleKeyboard() {
    if (_typing.hasFocus) {
      _typing.unfocus();
    } else {
      _typing.requestFocus();
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
    }
    setState(() {});
  }

  // ── pointer lock ──

  Future<void> _lock() async {
    final s = _session;
    if (s == null || !_PointerLock.supported) return;
    _PointerLock.onMoved = (dx, dy) => _session?.relative(dx, dy);
    _PointerLock.onUnlocked = () => _session?.setLocked(false);
    if (await _PointerLock.lock()) s.setLocked(true);
    _focus.requestFocus();
  }

  Future<void> _unlock() async {
    _session?.setLocked(false);
    await _PointerLock.unlock();
  }

  void _toggleFull() {
    if (widget.full) {
      Navigator.of(context).maybePop();
      return;
    }
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (_, _, _) => Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: DesktopView(session: widget.session, full: true),
          ),
        ),
      ),
    );
  }

  // ── layout ──

  @override
  Widget build(BuildContext context) {
    final s = _session;
    if (s == null) {
      return const _Message(
        icon: Icons.desktop_access_disabled_outlined,
        text: 'This view has closed',
      );
    }
    final touch = Platform.isAndroid || Platform.isIOS;
    final width = (s.info['width'] as num?)?.toDouble() ?? 16;
    final height = (s.info['height'] as num?)?.toDouble() ?? 9;
    final sourceWidth = (s.info['sourceWidth'] as num?)?.toDouble() ?? width;
    final picture = AspectRatio(
      aspectRatio: width / height,
      child: LayoutBuilder(
        builder: (context, box) {
          final size = box.biggest;
          return MouseRegion(
            cursor: s.locked ? SystemMouseCursors.none : MouseCursor.defer,
            child: Listener(
              onPointerDown: (e) {
                if (!_typing.hasFocus) _focus.requestFocus();
                if (e.kind == PointerDeviceKind.touch) {
                  _touchDown(e, size);
                } else {
                  _pointer(e, size);
                }
              },
              onPointerUp: (e) => e.kind == PointerDeviceKind.touch
                  ? _touchUp(e)
                  : _pointer(e, size),
              onPointerMove: (e) => e.kind == PointerDeviceKind.touch
                  ? _touchMove(e, size)
                  : _pointer(e, size),
              onPointerHover: (e) => _pointer(e, size),
              onPointerCancel: (e) {
                _touchUp(e);
                s.buttons(0);
              },
              onPointerSignal: (e) {
                if (e is PointerScrollEvent) {
                  GestureBinding.instance.pointerSignalResolver.register(e, (
                    _,
                  ) {
                    s.wheel(-e.scrollDelta.dy / _pixelsPerNotch);
                    s.wheel(
                      e.scrollDelta.dx / _pixelsPerNotch,
                      horizontal: true,
                    );
                  });
                }
              },
              onPointerPanZoomUpdate: (e) {
                s.wheel(e.panDelta.dy / _pixelsPerNotch);
                s.wheel(-e.panDelta.dx / _pixelsPerNotch, horizontal: true);
              },
              child: ColoredBox(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (s.textureId != null)
                      Texture(
                        textureId: s.textureId!,
                        filterQuality: FilterQuality.medium,
                      ),
                    // Without a pointer of its own over the picture (touch,
                    // or locked), the other device's is drawn.
                    if (touch || s.locked)
                      ValueListenableBuilder(
                        valueListenable: s.cursor,
                        builder: (context, cursor, _) => CustomPaint(
                          painter: _CursorPainter(
                            cursor,
                            size.width / sourceWidth,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    final displays = (s.info['displays'] as List?) ?? const [];
    final streaming = s.state == DesktopState.streaming;
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      onFocusChange: (focused) {
        if (!focused) {
          s.releaseAll();
          if (s.locked) unawaited(_unlock());
        }
        setState(() => _focused = focused);
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.full)
            Positioned.fill(child: Center(child: picture))
          else
            picture,
          // Raises the phone's keyboard; what it types goes to the other
          // device (see [_softTyped]).
          Positioned(
            left: 0,
            bottom: 0,
            width: 1,
            height: 1,
            child: Opacity(
              opacity: 0,
              child: TextField(
                focusNode: _typing,
                controller: _typed,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.multiline,
                maxLines: null,
                onChanged: _softTyped,
              ),
            ),
          ),
          if (!streaming || s.framesReceived == 0)
            _Message(
              icon: switch (s.state) {
                DesktopState.connecting ||
                DesktopState.streaming => Icons.cast_connected,
                DesktopState.ended => Icons.desktop_access_disabled_outlined,
                DesktopState.failed => Icons.error_outline,
              },
              text: switch (s.state) {
                DesktopState.connecting => 'Connecting to ${s.deviceName}…',
                DesktopState.streaming => 'Waiting for the first picture…',
                DesktopState.ended || DesktopState.failed =>
                  s.error.isEmpty ? 'The session ended' : s.error,
              },
            ),
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: widget.showStats && _stats && streaming
                        ? _Stats(session: s)
                        : const SizedBox.shrink(),
                  ),
                ),
                if (s.preview && streaming)
                  const _Chip(
                    text: 'Preview of this screen · no control',
                    color: Colors.black54,
                  )
                else if (s.locked)
                  const _Chip(
                    text: 'Pointer locked · Ctrl+Alt+Shift+L frees it',
                    color: Colors.black54,
                  )
                else if (!touch && !_focused && streaming)
                  _Chip(
                    text: 'Click to control',
                    color: Theme.of(context).colorScheme.primary,
                  ),
                if (streaming && !s.preview) ...[
                  if (touch)
                    _Tool(
                      icon: Icons.keyboard,
                      tooltip: 'Keyboard',
                      on: _typing.hasFocus,
                      onPressed: _toggleKeyboard,
                    ),
                  if (_PointerLock.supported && !touch)
                    _Tool(
                      icon: Icons.mouse,
                      tooltip: s.locked
                          ? 'Free the pointer (Ctrl+Alt+Shift+L)'
                          : 'Lock the pointer for games (Ctrl+Alt+Shift+L)',
                      on: s.locked,
                      onPressed: () =>
                          unawaited(s.locked ? _unlock() : _lock()),
                    ),
                  if (s.info['audio'] == true)
                    _Tool(
                      icon: s.sound ? Icons.volume_up : Icons.volume_off,
                      tooltip: s.sound ? 'Mute' : 'Sound on',
                      on: s.sound,
                      onPressed: () => s.setSound(!s.sound),
                    ),
                  if (s.info['clipboard'] == true && touch)
                    _Tool(
                      icon: Icons.content_paste_go,
                      tooltip: 'Send this clipboard',
                      onPressed: () async {
                        final sent = await s.sendClipboard();
                        if (!context.mounted) return;
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          SnackBar(
                            content: Text(
                              sent
                                  ? 'Clipboard sent'
                                  : 'No text in the clipboard',
                            ),
                          ),
                        );
                      },
                    ),
                  if (displays.length > 1)
                    PopupMenuButton<int>(
                      tooltip: 'Display',
                      initialValue: (s.info['display'] as num?)?.toInt(),
                      onSelected: s.selectDisplay,
                      itemBuilder: (_) => [
                        for (var i = 0; i < displays.length; i++)
                          PopupMenuItem(
                            value: i,
                            child: Text(
                              'Display ${i + 1} · '
                              '${(displays[i] as Map)['width']}×'
                              '${(displays[i] as Map)['height']}',
                            ),
                          ),
                      ],
                      child: const _Tool(
                        icon: Icons.monitor,
                        tooltip: null,
                        onPressed: null,
                      ),
                    ),
                  if (widget.showStats)
                    _Tool(
                      icon: Icons.speed,
                      tooltip: _stats ? 'Hide figures' : 'Show figures',
                      on: _stats,
                      onPressed: () => setState(() => _stats = !_stats),
                    ),
                ],
                _Tool(
                  icon: widget.full ? Icons.fullscreen_exit : Icons.fullscreen,
                  tooltip: widget.full
                      ? 'Leave full view (Ctrl+Alt+Shift+F)'
                      : 'Full view (Ctrl+Alt+Shift+F)',
                  onPressed: _toggleFull,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CursorPainter extends CustomPainter {
  final DesktopCursor? cursor;
  final double scale;
  _CursorPainter(this.cursor, this.scale);

  @override
  void paint(Canvas canvas, Size size) {
    final c = cursor;
    final image = c?.image;
    if (c == null || image == null || !c.visible) return;
    final at = Offset(c.x * scale, c.y * scale);
    // At least its own size: a scaled-down stream keeps a usable pointer.
    final s = scale.clamp(1.0, 4.0);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(at.dx, at.dy, image.width * s, image.height * s),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_CursorPainter old) =>
      old.cursor != cursor || old.scale != scale;
}

class _Tool extends StatelessWidget {
  final IconData icon;
  final String? tooltip;
  final bool on;
  final VoidCallback? onPressed;
  const _Tool({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.on = false,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: Material(
      color: on
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.85)
          : Colors.black54,
      shape: const CircleBorder(),
      child: onPressed == null
          ? Padding(
              padding: const EdgeInsets.all(10),
              child: Icon(icon, color: Colors.white, size: 20),
            )
          : IconButton(
              tooltip: tooltip,
              color: Colors.white,
              iconSize: 20,
              icon: Icon(icon),
              onPressed: onPressed,
            ),
    ),
  );
}

class _Stats extends StatelessWidget {
  final DesktopSession session;
  const _Stats({required this.session});

  @override
  Widget build(BuildContext context) {
    final i = session.info;
    String n(Object? v, [int digits = 0]) =>
        v is num ? v.toStringAsFixed(digits) : '–';
    final parts = [
      '${n(i['width'])}×${n(i['height'])}',
      '${n(i['fps'])} fps',
      '${((i['kbps'] as num? ?? 0) / 1000).toStringAsFixed(1)} Mbit/s',
      '${n(i['latency'], 1)} ms',
      'decode ${(session.decodeMicros / 1000).toStringAsFixed(1)} ms',
      if (i['encoder'] is String) '${i['encoder']}',
    ];
    return _Chip(text: parts.join(' · '), color: Colors.black54);
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final Color color;
  const _Chip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 12),
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Message({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white70, size: 36),
        const SizedBox(height: 8),
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      ],
    ),
  );
}
