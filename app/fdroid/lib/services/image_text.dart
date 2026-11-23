import 'dart:typed_data';

/// Keep's "Grab image text" needs ML Kit, which is not free software, so the
/// F-Droid build leaves it out (lib/services/image_text.dart is the real one).
class ImageText {
  static bool get supported => false;

  static Future<String> read(Uint8List bytes, String name) =>
      throw UnsupportedError('This build of OurNet cannot read image text.');
}
