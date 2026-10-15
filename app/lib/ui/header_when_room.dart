import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A scrolling column topped by [header] while everything fits; once
/// [children] alone would need scrolling with it, the header is left out so
/// the space goes to them. Both are measured each layout, and the header
/// only counts its own height, so leaving it out cannot flip the decision.
class HeaderWhenRoom extends StatefulWidget {
  const HeaderWhenRoom({
    super.key,
    required this.header,
    required this.children,
  });

  final Widget header;
  final List<Widget> children;

  @override
  State<HeaderWhenRoom> createState() => _HeaderWhenRoomState();
}

class _HeaderWhenRoomState extends State<HeaderWhenRoom> {
  double? header;
  double? body;

  void measured(void Function() change) {
    if (mounted) setState(change);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final h = header, b = body;
      final room = h == null || b == null || h + b <= constraints.maxHeight;
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Offstage still lays the header out, so it stays measured.
            Offstage(
              offstage: !room,
              child: _Measure(
                onSize: (s) => measured(() => header = s.height),
                child: widget.header,
              ),
            ),
            _Measure(
              onSize: (s) => measured(() => body = s.height),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.children,
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _Measure extends SingleChildRenderObjectWidget {
  const _Measure({required this.onSize, super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasure(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasure renderObject) =>
      renderObject.onSize = onSize;
}

class _RenderMeasure extends RenderProxyBox {
  _RenderMeasure(this.onSize);

  ValueChanged<Size> onSize;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    final now = size;
    if (now == _last) return;
    _last = now;
    // Reported after the frame: layout must not mark widgets dirty.
    WidgetsBinding.instance.addPostFrameCallback((_) => onSize(now));
  }
}
