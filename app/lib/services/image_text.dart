import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:ournet_core/ournet_core.dart' show randomId;
import 'package:path_provider/path_provider.dart';

/// Keep's "Grab image text": on-device text recognition (ML Kit's bundled
/// Latin-script model) on Android. Images are not uploaded. The decrypted
/// image exists as a temporary file only while it is read.
class ImageText {
  static bool get supported => Platform.isAndroid;

  static Future<String> read(Uint8List bytes, String name) async {
    if (!supported) {
      throw UnsupportedError('Reading text from images needs Android.');
    }
    final folder = Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}ournet-ocr',
    )..createSync(recursive: true);
    final extension =
        RegExp(r'\.([A-Za-z0-9]{1,5})$').firstMatch(name)?.group(1) ?? 'jpg';
    final file = File(
      '${folder.path}${Platform.pathSeparator}${randomId().replaceAll(RegExp('[^A-Za-z0-9]'), '')}.$extension',
    );
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      await file.writeAsBytes(bytes, flush: true);
      final result = await recognizer.processImage(
        InputImage.fromFilePath(file.path),
      );
      return result.text.trim();
    } finally {
      await recognizer.close();
      if (await file.exists()) await file.delete();
    }
  }
}
