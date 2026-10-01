import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

const _channel = MethodChannel('ournet/clipboard');

/// The clipboard's image as PNG-or-native bytes, or null when it holds none.
/// `pasteboard` has no Android implementation, so Android asks the activity.
Future<Uint8List?> clipboardImage() async {
  try {
    if (Platform.isAndroid) {
      final path = await _channel.invokeMethod<String>('image');
      if (path == null) return null;
      final file = File(path);
      try {
        return await file.readAsBytes();
      } finally {
        if (await file.exists()) await file.delete();
      }
    }
    return await Pasteboard.image;
  } on MissingPluginException {
    return null;
  }
}
