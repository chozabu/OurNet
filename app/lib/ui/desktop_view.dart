import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/remote_desktop.dart';

/// Another device's desktop: the decoded stream as a texture, with this
/// device's mouse and keyboard sent back while it is focused (click it).
/// Plugins show it as `DesktopView` with the `session` their
/// `remote-desktop.view` returned. See docs/REMOTE_DESKTOP.md.
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

class _DesktopViewState extends State<DesktopView> {
  final _focus = FocusNode(debugLabel: 'Remote desktop');
  DesktopSession? _session;
  bool _focused = false;

  /// Flutter's scroll delta for one wheel notch on Windows.
  static const _pixelsPerNotch = 20.0;

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
    _session?.releaseAll();
    _session?.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  void _pointer(PointerEvent event, Size size) {
    final s = _session;
    if (s == null || size.isEmpty) return;
    s.pointer(
      event.localPosition.dx / size.width,
      event.localPosition.dy / size.height,
    );
    s.buttons(event.buttons);
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    final s = _session;
    if (s == null) return KeyEventResult.ignored;
    // Ctrl+Alt+Shift+F leaves or enters the full view; every other key
    // goes to the other device, so its shortcuts work and ours do not fire.
    final keys = HardwareKeyboard.instance;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyF &&
        keys.isControlPressed &&
        keys.isAltPressed &&
        keys.isShiftPressed) {
      s.releaseAll();
      _toggleFull();
      return KeyEventResult.handled;
    }
    final usage = event.physicalKey.usbHidUsage;
    if (usage >> 16 != 0x07) return KeyEventResult.handled;
    if (event is KeyDownEvent) s.key(usage & 0xffff, true);
    if (event is KeyUpEvent) s.key(usage & 0xffff, false);
    return KeyEventResult.handled;
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
          body: DesktopView(session: widget.session, full: true),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    if (s == null) {
      return const _Message(
        icon: Icons.desktop_access_disabled_outlined,
        text: 'This view has closed',
      );
    }
    final width = (s.info['width'] as num?)?.toDouble() ?? 16;
    final height = (s.info['height'] as num?)?.toDouble() ?? 9;
    final picture = AspectRatio(
      aspectRatio: width / height,
      child: LayoutBuilder(
        builder: (context, box) {
          final size = box.biggest;
          return Listener(
            onPointerDown: (e) {
              _focus.requestFocus();
              _pointer(e, size);
            },
            onPointerUp: (e) => _pointer(e, size),
            onPointerMove: (e) => _pointer(e, size),
            onPointerHover: (e) => _pointer(e, size),
            onPointerCancel: (_) => s.buttons(0),
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                GestureBinding.instance.pointerSignalResolver.register(e, (_) {
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
              child: s.textureId == null
                  ? const SizedBox.expand()
                  : Texture(
                      textureId: s.textureId!,
                      filterQuality: FilterQuality.medium,
                    ),
            ),
          );
        },
      ),
    );
    final theme = Theme.of(context);
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      onFocusChange: (focused) {
        if (!focused) s.releaseAll();
        setState(() => _focused = focused);
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.full) Positioned.fill(child: Center(child: picture)) else picture,
          if (s.state != DesktopState.streaming || s.framesReceived == 0)
            _Message(
              icon: switch (s.state) {
                DesktopState.connecting || DesktopState.streaming =>
                  Icons.cast_connected,
                DesktopState.ended => Icons.desktop_access_disabled_outlined,
                DesktopState.failed => Icons.error_outline,
              },
              text: switch (s.state) {
                DesktopState.connecting =>
                  'Connecting to ${s.deviceName}…',
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
                    child:
                        widget.showStats && s.state == DesktopState.streaming
                        ? _Stats(session: s)
                        : const SizedBox.shrink(),
                  ),
                ),
                if (s.preview && s.state == DesktopState.streaming)
                  const _Chip(
                    text: 'Preview of this screen · no control',
                    color: Colors.black54,
                  )
                else if (!_focused && s.state == DesktopState.streaming)
                  _Chip(
                    text: 'Click to control',
                    color: theme.colorScheme.primary,
                  ),
                const SizedBox(width: 6),
                Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: IconButton(
                    tooltip: widget.full
                        ? 'Leave full view (Ctrl+Alt+Shift+F)'
                        : 'Full view (Ctrl+Alt+Shift+F)',
                    color: Colors.white,
                    iconSize: 20,
                    icon: Icon(
                      widget.full ? Icons.fullscreen_exit : Icons.fullscreen,
                    ),
                    onPressed: _toggleFull,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
