
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Opens an image full screen: the whole picture fits the window, and it can
/// be pinched, scrolled or double-tapped to zoom and dragged when zoomed.
/// [preview] is shown, uncropped, while the original loads.
Future<void> showImageViewer(
  BuildContext context, {
  required Future<Uint8List> bytes,
  ImageProvider? preview,
  String? title,
}) => Navigator.of(context).push<void>(
  PageRouteBuilder<void>(
    opaque: false,
    fullscreenDialog: true,
    barrierColor: Colors.black,
    transitionDuration: const Duration(milliseconds: 160),
    reverseTransitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (_, _, _) =>
        ImageViewer(bytes: bytes, preview: preview, title: title),
    transitionsBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  ),
);

class ImageViewer extends StatefulWidget {
  final Future<Uint8List> bytes;
  final ImageProvider? preview;
  final String? title;
  const ImageViewer({super.key, required this.bytes, this.preview, this.title});
  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer>
    with SingleTickerProviderStateMixin {
  static const maxScale = 8.0;
  final transform = TransformationController();
  late final AnimationController animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  Animation<Matrix4>? tween;
  Offset doubleTapAt = Offset.zero;
  bool zoomed = false;

  @override
  void initState() {
    super.initState();
    animation.addListener(() {
      if (tween != null) transform.value = tween!.value;
    });
    transform.addListener(() {
      final now = transform.value.getMaxScaleOnAxis() > 1.01;
      if (now != zoomed) setState(() => zoomed = now);
    });
  }

  @override
  void dispose() {
    animation.dispose();
    transform.dispose();
    super.dispose();
  }

  void animateTo(Matrix4 target) {
    tween = Matrix4Tween(
      begin: transform.value,
      end: target,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut));
    animation.forward(from: 0);
  }

  void toggleZoom() {
    if (transform.value.getMaxScaleOnAxis() > 1.01) {
      animateTo(Matrix4.identity());
    } else {
      const scale = 3.0;
      final p = doubleTapAt;
      animateTo(
        Matrix4.identity()
          ..translateByDouble(-p.dx * (scale - 1), -p.dy * (scale - 1), 0, 1)
          ..scaleByDouble(scale, scale, 1, 1),
      );
    }
  }

  void zoomBy(double factor) {
    final size = context.size ?? Size.zero;
    final focal = Offset(size.width / 2, size.height / 2);
    final current = transform.value.getMaxScaleOnAxis();
    final next = (current * factor).clamp(1.0, maxScale);
    final f = next / current;
    final scene = transform.toScene(focal);
    animateTo(
      Matrix4.copy(transform.value)
        ..translateByDouble(scene.dx, scene.dy, 0, 1)
        ..scaleByDouble(f, f, 1, 1)
        ..translateByDouble(-scene.dx, -scene.dy, 0, 1),
    );
  }

  static const failed = Center(
    child: Text(
      'Image could not be displayed',
      style: TextStyle(color: Colors.white70),
    ),
  );

  Widget picture() => FutureBuilder<Uint8List>(
    future: widget.bytes,
    builder: (context, snapshot) {
      if (snapshot.hasError) return failed;
      final ImageProvider? image = snapshot.hasData
          ? ResizeImage(
              MemoryImage(snapshot.data!),
              width: 3072,
              height: 3072,
              policy: ResizeImagePolicy.fit,
              allowUpscaling: false,
            )
          : widget.preview;
      return Stack(
        fit: StackFit.expand,
        children: [
          if (image != null)
            Image(
              image: image,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => failed,
            ),
          if (!snapshot.hasData)
            const Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.all(24),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    void close() => Navigator.of(context).maybePop();
    final buttons = IconButton.styleFrom(backgroundColor: Colors.black54);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): close,
        const SingleActivator(LogicalKeyboardKey.equal): () => zoomBy(1.5),
        const SingleActivator(LogicalKeyboardKey.add): () => zoomBy(1.5),
        const SingleActivator(LogicalKeyboardKey.minus): () => zoomBy(1 / 1.5),
        const SingleActivator(LogicalKeyboardKey.digit0): () =>
            animateTo(Matrix4.identity()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTapDown: (d) => doubleTapAt = d.localPosition,
                onDoubleTap: toggleZoom,
                // A quick vertical flick at 1x closes, like most photo viewers.
                onVerticalDragEnd: (d) {
                  if (!zoomed && (d.primaryVelocity ?? 0).abs() > 900) close();
                },
                child: InteractiveViewer(
                  transformationController: transform,
                  minScale: 1,
                  maxScale: maxScale,
                  child: SizedBox.expand(child: picture()),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Close',
                        color: Colors.white,
                        style: buttons,
                        onPressed: close,
                        icon: const Icon(Icons.close),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.title ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            shadows: [Shadow(blurRadius: 6)],
                          ),
                        ),
                      ),
                      if (zoomed)
                        IconButton(
                          tooltip: 'Fit to screen',
                          color: Colors.white,
                          style: buttons,
                          onPressed: () => animateTo(Matrix4.identity()),
                          icon: const Icon(Icons.fit_screen),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
