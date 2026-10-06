import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

/// A profile picture decoded at about the size it is shown. The cache key is
/// the object that carried it and a size bucket, so rows that rebuild or
/// scroll back reuse one decode, and a new picture never shows a stale one.
@immutable
class AvatarImage extends ImageProvider<AvatarImage> {
  final Avatar avatar;

  /// Physical pixels along each side, from [bucket].
  final int size;
  const AvatarImage(this.avatar, this.size);

  /// Rounds [physical] pixels up to one of a few sizes, so the same picture
  /// is not decoded once per slightly different place it appears.
  static int bucket(double physical) {
    for (final size in const [48, 96, 160]) {
      if (physical <= size) return size;
    }
    return Avatars.edge;
  }

  /// [avatar] for a circle [diameter] logical pixels across in [context].
  static AvatarImage? sized(
    BuildContext context,
    Avatar? avatar,
    double diameter,
  ) => avatar == null
      ? null
      : AvatarImage(
          avatar,
          bucket(diameter * MediaQuery.devicePixelRatioOf(context)),
        );

  @override
  Future<AvatarImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(AvatarImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_load(key, decode));

  static Future<ImageInfo> _load(
    AvatarImage key,
    ImageDecoderCallback decode,
  ) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(key.avatar.bytes);
    final codec = await decode(
      buffer,
      getTargetSize: (width, height) => width <= key.size
          ? ui.TargetImageSize(width: width, height: height)
          : ui.TargetImageSize(width: key.size),
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    return ImageInfo(image: frame.image, debugLabel: 'avatar/${key.avatar.id}');
  }

  @override
  bool operator ==(Object other) =>
      other is AvatarImage && other.avatar.id == avatar.id && other.size == size;

  @override
  int get hashCode => Object.hash(avatar.id, size);
}

/// Someone's picture in a circle, or the first letter of [label] until it
/// loads, when they have none, or if it cannot be decoded.
class ProfileAvatar extends StatelessWidget {
  final Avatar? avatar;
  final String label;
  final double radius;
  final Color? backgroundColor, foregroundColor;
  const ProfileAvatar({
    super.key,
    required this.avatar,
    required this.label,
    this.radius = 20,
    this.backgroundColor,
    this.foregroundColor,
  });

  static String initial(String label) {
    final trimmed = label.trim();
    // Whole characters, so a name starting with an emoji keeps it.
    return trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final image = AvatarImage.sized(context, avatar, radius * 2);
    return CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      foregroundImage: image,
      onForegroundImageError: image == null ? null : (_, _) {},
      child: Text(
        initial(label),
        style: radius < 14 ? TextStyle(fontSize: radius * 1.1) : null,
      ),
    );
  }
}
