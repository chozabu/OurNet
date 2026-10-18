/// RNNoise for call audio (`rust/src/denoise.rs`). The platform's capture
/// hook calls the native code directly on the audio thread; Dart only
/// switches it and, on desktop, tells the runner where it is.
@DefaultAsset('package:ournet_native/ournet_native.dart')
library;

import 'dart:ffi';

@Native<Void Function(Int32)>(
  symbol: 'ournet_denoise_set_enabled',
  isLeaf: true,
)
external void _setEnabled(int enabled);

@Native<Uint64 Function()>(symbol: 'ournet_denoise_frames', isLeaf: true)
external int _frames();

@Native<Uint64 Function()>(symbol: 'ournet_denoise_last_frame', isLeaf: true)
external int _lastFrame();

@Native<Void Function()>(symbol: 'ournet_denoise_reset', isLeaf: true)
external void _reset();

@Native<Int32 Function(Pointer<Float>, Size, Int32)>(
  symbol: 'ournet_denoise_process',
  isLeaf: true,
)
external int _process(Pointer<Float> buffer, int frames, int rate);

abstract final class NoiseSuppression {
  /// Whether this build has the native library (and so the denoiser).
  static final bool available = _probe();

  static bool _probe() {
    try {
      _frames();
      return true;
    } catch (_) {
      return false;
    }
  }

  static void setEnabled(bool enabled) {
    if (available) _setEnabled(enabled ? 1 : 0);
  }

  /// 10 ms capture frames denoised so far, across every call.
  static int get frames => available ? _frames() : 0;

  /// The sample rate and length of the last frame the platform offered
  /// while on, whether or not it could be denoised; null before any.
  static ({int rate, int frames})? get lastFrame {
    final last = available ? _lastFrame() : 0;
    if (last == 0) return null;
    return (rate: last >> 32, frames: last & 0xffffffff);
  }

  static void reset() {
    if (available) _reset();
  }

  /// The address of `ournet_denoise_process(float*, size_t, int32_t)`, for a
  /// runner that calls it from its capture hook; 0 without the library.
  static int get processAddress => available
      ? Native.addressOf<
              NativeFunction<Int32 Function(Pointer<Float>, Size, Int32)>
            >(_process)
            .address
      : 0;
}
