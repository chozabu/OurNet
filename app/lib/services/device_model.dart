import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('ournet/device');

/// This phone's model, e.g. "Pixel 8 Pro", as a name people recognise for a
/// new device; null where the platform does not say.
Future<String?> deviceModel() async {
  if (!Platform.isAndroid) return null;
  try {
    final model = (await _channel.invokeMethod<String>('model'))?.trim();
    return model == null || model.isEmpty ? null : model;
  } catch (_) {
    return null;
  }
}
