import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// The dark look both call screens share.
ThemeData callTheme() => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xff137d72),
    brightness: Brightness.dark,
  ),
  useMaterial3: true,
);

const callBackground = Color(0xff0e1214);

/// "02:31", or "1:02:31" past an hour.
String callDuration(DateTime? since) {
  if (since == null) return '';
  final s = DateTime.now().difference(since).inSeconds.clamp(0, 359999);
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}

/// A coloured initial for someone on a call without video.
class CallAvatar extends StatelessWidget {
  final String label;

  /// Picks the colour, so a person keeps theirs across tiles and screens.
  final Object? seed;
  final double size;
  const CallAvatar({super.key, required this.label, this.seed, this.size = 96});

  static const palette = [
    Color(0xff137d72),
    Color(0xff5c6bc0),
    Color(0xffc2185b),
    Color(0xffef6c00),
    Color(0xff6a1b9a),
    Color(0xff2e7d32),
    Color(0xff0277bd),
    Color(0xff8d6e63),
  ];

  @override
  Widget build(BuildContext context) {
    final initial = label.trim().isEmpty ? '?' : label.trim()[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: palette[(seed ?? label).hashCode.abs() % palette.length],
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * .45,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Rings that spread from an avatar while a call rings.
class RingingHalo extends StatefulWidget {
  final Widget child;
  final double size;
  const RingingHalo({super.key, required this.child, required this.size});
  @override
  State<RingingHalo> createState() => _RingingHaloState();
}

class _RingingHaloState extends State<RingingHalo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colour = Theme.of(context).colorScheme.primary;
    return SizedBox.square(
      dimension: widget.size * 1.7,
      child: AnimatedBuilder(
        animation: _wave,
        builder: (context, child) => Stack(
          alignment: Alignment.center,
          children: [
            for (final offset in const [0.0, .5])
              Builder(
                builder: (context) {
                  final t = (_wave.value + offset) % 1;
                  final d = widget.size * (1 + .7 * t);
                  return Container(
                    width: d,
                    height: d,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: colour.withValues(alpha: (1 - t) * .6),
                        width: 2,
                      ),
                    ),
                  );
                },
              ),
            child!,
          ],
        ),
        child: widget.child,
      ),
    );
  }
}

/// A round call control, optionally captioned underneath.
class CallButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool on;
  final Color? background, foreground;
  final String? caption;
  final double size;
  const CallButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.on = false,
    this.background,
    this.foreground,
    this.caption,
    this.size = 56,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final button = IconButton.filled(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: size * .46,
      style: IconButton.styleFrom(
        minimumSize: Size(size, size),
        backgroundColor:
            background ?? (on ? Colors.white : scheme.surfaceContainerHighest),
        foregroundColor: foreground ?? (on ? Colors.black87 : Colors.white),
      ),
      icon: Icon(icon),
    );
    if (caption == null) return button;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        const SizedBox(height: 6),
        Text(caption!, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}

/// A small view (usually your own camera) floating over a call. It can be
/// dragged, and settles in the nearest corner. Fill the call's stage with it:
/// only the view itself takes touches.
class FloatingView extends StatefulWidget {
  final Widget child;

  /// Space to keep clear at the stage's edges, such as under the controls.
  final EdgeInsets padding;
  const FloatingView({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  /// The view's size on a stage of [box]: a portrait slice of a phone, a
  /// landscape one of a desktop window.
  static Size sizeFor(Size box) {
    if (box.height >= box.width) {
      final w = (box.width * .28).clamp(84.0, 180.0);
      return Size(w, w * 4 / 3);
    }
    final h = (box.height * .24).clamp(72.0, 200.0);
    return Size(h * 4 / 3, h);
  }

  @override
  State<FloatingView> createState() => _FloatingViewState();
}

class _FloatingViewState extends State<FloatingView> {
  Alignment _corner = Alignment.bottomRight;
  Offset? _drag;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const margin = 12.0;
      final size = FloatingView.sizeFor(box.biggest);
      final pad = widget.padding;
      Offset place(Alignment a) => Offset(
        a.x < 0
            ? margin + pad.left
            : box.maxWidth - size.width - margin - pad.right,
        a.y < 0
            ? margin + pad.top
            : box.maxHeight - size.height - margin - pad.bottom,
      );
      final at = _drag ?? place(_corner);
      return Stack(
        children: [
          AnimatedPositioned(
            duration: _drag == null
                ? const Duration(milliseconds: 220)
                : Duration.zero,
            curve: Curves.easeOutCubic,
            left: at.dx,
            top: max(0, at.dy),
            width: size.width,
            height: size.height,
            child: GestureDetector(
              onPanStart: (_) => setState(() => _drag = place(_corner)),
              onPanUpdate: (d) => setState(() => _drag = _drag! + d.delta),
              onPanEnd: (_) => setState(() {
                final centre = _drag! + Offset(size.width / 2, size.height / 2);
                _corner = Alignment(
                  centre.dx < box.maxWidth / 2 ? -1 : 1,
                  centre.dy < box.maxHeight / 2 ? -1 : 1,
                );
                _drag = null;
              }),
              child: Material(
                elevation: 8,
                color: const Color(0xff1b2226),
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(14),
                child: widget.child,
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// Video from [renderer], filling its box.
class CallVideo extends StatelessWidget {
  final RTCVideoRenderer renderer;
  final bool mirror;

  /// Shows the whole picture (letterboxed) rather than filling and cropping.
  final bool whole;
  const CallVideo(
    this.renderer, {
    super.key,
    this.mirror = false,
    this.whole = false,
  });

  @override
  Widget build(BuildContext context) => RTCVideoView(
    renderer,
    mirror: mirror,
    objectFit: whole
        ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
        : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
  );
}

/// Microphone and speaker choice on desktop.
Future<void> showCallDevices(
  BuildContext context, {
  required Listenable listenable,
  required List<MediaDeviceInfo> Function() inputs,
  required List<MediaDeviceInfo> Function() outputs,
  required String? Function() input,
  required String? Function() output,
  required void Function(String) selectInput,
  required void Function(String) selectOutput,
}) => showModalBottomSheet<void>(
  context: context,
  builder: (context) => ListenableBuilder(
    listenable: listenable,
    builder: (context, _) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (inputs().isNotEmpty)
              DropdownButtonFormField<String>(
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Microphone'),
                initialValue: input(),
                items: [
                  for (final d in inputs())
                    DropdownMenuItem(
                      value: d.deviceId,
                      child: Text(d.label.isEmpty ? d.deviceId : d.label),
                    ),
                ],
                onChanged: (id) {
                  if (id != null) selectInput(id);
                },
              ),
            const SizedBox(height: 12),
            if (outputs().isNotEmpty)
              DropdownButtonFormField<String>(
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Speakers'),
                initialValue: output(),
                items: [
                  for (final d in outputs())
                    DropdownMenuItem(
                      value: d.deviceId,
                      child: Text(d.label.isEmpty ? d.deviceId : d.label),
                    ),
                ],
                onChanged: (id) {
                  if (id != null) selectOutput(id);
                },
              ),
          ],
        ),
      ),
    ),
  ),
);
