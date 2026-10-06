import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ournet_core/ournet_core.dart';

import 'drawing.dart';

/// What the person chose for their profile picture: new pixels, at most
/// [Avatars.edge] square, or none ([rgba] null) to remove it.
typedef AvatarChoice = ({Uint8List? rgba, int edge});

/// Asks where a new picture comes from, then lets the person frame it.
/// Null when they changed their mind.
Future<AvatarChoice?> chooseAvatar(
  BuildContext context, {
  required bool hasPicture,
}) async {
  final camera =
      !Platform.environment.containsKey('FLUTTER_TEST') &&
      ImagePicker().supportsImageSource(ImageSource.camera);
  final source = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Anyone who can see your name can see your picture.',
            ),
          ),
          if (camera)
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('Choose image'),
            onTap: () => Navigator.pop(context, 'gallery'),
          ),
          ListTile(
            leading: const Icon(Icons.brush_outlined),
            title: const Text('Draw one'),
            onTap: () => Navigator.pop(context, 'draw'),
          ),
          if (hasPicture)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove picture'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return null;
  if (source == 'remove') return (rgba: null, edge: 0);
  final Uint8List bytes;
  if (source == 'draw') {
    final drawing = await editDrawing(context, strokes: const []);
    if (drawing == null) return null;
    bytes = drawing.png;
  } else {
    final picked = await ImagePicker().pickImage(
      source: source == 'camera' ? ImageSource.camera : ImageSource.gallery,
      preferredCameraDevice: CameraDevice.front,
      // Where the platform can, it hands over a smaller, upright copy.
      maxWidth: AvatarCropPage.maxEdge.toDouble(),
      maxHeight: AvatarCropPage.maxEdge.toDouble(),
    );
    if (picked == null) return null;
    bytes = await picked.readAsBytes();
  }
  if (!context.mounted) return null;
  final rgba = await Navigator.of(context).push<Uint8List>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => AvatarCropPage(bytes: bytes),
    ),
  );
  return rgba == null ? null : (rgba: rgba, edge: Avatars.edge);
}

/// Decodes [bytes] for framing, its longer side at most
/// [AvatarCropPage.maxEdge]. The engine decodes off this thread.
Future<ui.Image> decodeForCrop(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodecWithSize(
    await ui.ImmutableBuffer.fromUint8List(bytes),
    // Only a width: a photo whose stored orientation is turned keeps its
    // proportions whichever way the engine reports it.
    getTargetSize: (width, height) {
      final longest = math.max(width, height);
      if (longest <= AvatarCropPage.maxEdge) {
        return ui.TargetImageSize(width: width, height: height);
      }
      return ui.TargetImageSize(
        width: (width * AvatarCropPage.maxEdge / longest).round(),
      );
    },
  );
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

/// Draws [source] (in [image]'s pixels) into an [Avatars.edge] square and
/// returns its straight RGBA pixels. Scaling runs on the GPU.
Future<Uint8List> cropAvatar(ui.Image image, Rect source) async {
  const edge = Avatars.edge;
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    image,
    source,
    const Rect.fromLTWH(0, 0, edge * 1.0, edge * 1.0),
    // Mipmapped sampling: smooth when shrinking a large photo.
    Paint()..filterQuality = FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final out = await picture.toImage(edge, edge);
  picture.dispose();
  try {
    final data = await out.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (data == null) throw StateError('The picture could not be read');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    out.dispose();
  }
}

/// Frames a picture in a circle: drag to move, pinch or scroll to zoom.
/// Pops with the framed pixels, or nothing when cancelled.
class AvatarCropPage extends StatefulWidget {
  /// The longest side kept for framing; far more than [Avatars.edge], so
  /// zooming in stays sharp, but bounded for memory.
  static const maxEdge = 2048;

  final Uint8List bytes;
  const AvatarCropPage({super.key, required this.bytes});

  @override
  State<AvatarCropPage> createState() => _AvatarCropPageState();
}

class _AvatarCropPageState extends State<AvatarCropPage> {
  final _transform = TransformationController();
  ui.Image? _image;
  Object? _error;
  double? _viewport;
  bool _cropping = false;

  @override
  void initState() {
    super.initState();
    decodeForCrop(widget.bytes).then(
      (image) {
        if (mounted) {
          setState(() => _image = image);
        } else {
          image.dispose();
        }
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = e);
      },
    );
  }

  @override
  void dispose() {
    _transform.dispose();
    _image?.dispose();
    super.dispose();
  }

  /// The smallest scale at which [image] still fills the circle.
  double _cover(ui.Image image, double viewport) =>
      viewport / math.min(image.width, image.height);

  /// Fills the circle and centres the picture, when first shown and when the
  /// window changes size.
  void _fit(ui.Image image, double viewport) {
    if (_viewport == viewport) return;
    _viewport = viewport;
    final scale = _cover(image, viewport);
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        (viewport - image.width * scale) / 2,
        (viewport - image.height * scale) / 2,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
  }

  Future<void> _use() async {
    final image = _image, viewport = _viewport;
    if (image == null || viewport == null || _cropping) return;
    setState(() => _cropping = true);
    try {
      final visible = Rect.fromPoints(
        _transform.toScene(Offset.zero),
        _transform.toScene(Offset(viewport, viewport)),
      ).intersect(
        Rect.fromLTWH(0, 0, image.width * 1.0, image.height * 1.0),
      );
      final rgba = await cropAvatar(image, visible);
      if (mounted) Navigator.pop(context, rgba);
    } catch (e) {
      if (mounted) {
        setState(() => _cropping = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not use it: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Frame your picture'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: image == null || _cropping ? null : _use,
              child: const Text('Use'),
            ),
          ),
        ],
      ),
      body: _error != null
          ? const Center(child: Text('That image cannot be opened.'))
          : image == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: LayoutBuilder(
                builder: (context, box) {
                  final viewport = math.min(
                    480.0,
                    math.min(box.maxWidth, box.maxHeight - 64) - 32,
                  );
                  _fit(image, viewport);
                  final cover = _cover(image, viewport);
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox.square(
                        dimension: viewport,
                        child: ClipRect(
                          child: Stack(
                            children: [
                              InteractiveViewer(
                                transformationController: _transform,
                                constrained: false,
                                // The picture always covers the circle.
                                boundaryMargin: EdgeInsets.zero,
                                minScale: cover,
                                maxScale: cover * 8,
                                child: SizedBox(
                                  width: image.width * 1.0,
                                  height: image.height * 1.0,
                                  child: RawImage(
                                    image: image,
                                    filterQuality: FilterQuality.medium,
                                  ),
                                ),
                              ),
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: CustomPaint(
                                    painter: _CircleMask(
                                      Theme.of(context).colorScheme.surface,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Drag to move. Pinch or scroll to zoom.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  );
                },
              ),
            ),
    );
  }
}

/// Dims everything outside the circle the picture will be shown in.
class _CircleMask extends CustomPainter {
  final Color color;
  _CircleMask(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(bounds),
        Path()..addOval(bounds.deflate(1)),
      ),
      Paint()..color = color.withValues(alpha: .72),
    );
    canvas.drawOval(
      bounds.deflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white70,
    );
  }

  @override
  bool shouldRepaint(_CircleMask old) => old.color != color;
}
