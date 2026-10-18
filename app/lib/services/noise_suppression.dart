import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ournet_core/ournet_core.dart';

/// RNNoise on the microphone in calls (`native/rust/src/denoise.rs`), after
/// WebRTC's own echo cancelling and noise suppression. flutter_webrtc gives
/// each platform a capture hook; the runner (`windows/runner/
/// noise_suppression.cpp`) or `NoiseSuppressor.kt` on Android puts the
/// native denoiser in it the first time a call starts with this on. Until
/// then the hook stays empty, and while off it passes audio through as is.
abstract final class CallNoiseSuppression {
  static const _channel = MethodChannel('ournet/denoise');
  static const setting = 'callNoiseSuppression';

  /// Platforms with a hook here, in builds that have the native library.
  static bool get supported =>
      NoiseSuppression.available && (Platform.isWindows || Platform.isAndroid);

  static bool _enabled = false;
  static bool get enabled => _enabled;
  static Future<void>? _attached;

  /// Takes the saved choice; called once the profile is open.
  static void load(Store store) {
    _enabled = supported && store.setting(setting) == true;
    NoiseSuppression.setEnabled(_enabled);
  }

  /// Switches it, for the call in progress too.
  static Future<void> set(Store store, bool value) async {
    store.set(setting, value);
    load(store);
    if (_enabled) await prepare();
  }

  /// Puts the denoiser in the capture hook if it is on; before each capture.
  static Future<void> prepare() async {
    if (!_enabled) return;
    _attached ??= _attach();
    await _attached;
  }

  static Future<void> _attach() async {
    try {
      // Android's hook exists once flutter_webrtc has made its factory.
      if (Platform.isAndroid) await WebRTC.initialize();
      await _channel.invokeMethod<void>('attach', {
        'process': NoiseSuppression.processAddress,
      });
    } catch (e) {
      debugPrint('Noise suppression unavailable: $e');
      _attached = null; // Try again with the next call.
    }
  }
}
