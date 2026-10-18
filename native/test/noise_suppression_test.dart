import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:ournet_native/noise_suppression.dart';
import 'package:test/test.dart';

typedef _Process = Int32 Function(Pointer<Float>, Size, Int32);

/// The runners call the denoiser through the address Dart hands them; it
/// must be the real function, and do nothing while switched off.
void main() {
  test('denoises through the address given to the runners', () {
    expect(NoiseSuppression.available, isTrue);
    final process = Pointer<NativeFunction<_Process>>.fromAddress(
      NoiseSuppression.processAddress,
    ).asFunction<int Function(Pointer<Float>, int, int)>(isLeaf: true);
    final random = Random(1);
    final buffer = malloc<Float>(480);
    addTearDown(() => malloc.free(buffer));
    final frame = buffer.asTypedList(480);
    void fill() {
      for (var i = 0; i < frame.length; i++) {
        frame[i] = (random.nextDouble() - 0.5) * 4000;
      }
    }

    fill();
    final original = Float32List.fromList(frame);
    NoiseSuppression.setEnabled(false);
    expect(process(buffer, frame.length, 48000), 0);
    expect(frame, original);

    NoiseSuppression.setEnabled(true);
    final before = NoiseSuppression.frames;
    var input = 0.0, output = 0.0;
    for (var i = 0; i < 200; i++) {
      fill();
      for (final x in frame) {
        input += x * x;
      }
      expect(process(buffer, frame.length, 48000), 1);
      for (final x in frame) {
        output += x * x;
      }
    }
    NoiseSuppression.setEnabled(false);
    expect(NoiseSuppression.frames - before, 200);
    // How much is the Rust test's business; here it only has to act.
    expect(output, lessThan(input * 0.9));
  });
}
