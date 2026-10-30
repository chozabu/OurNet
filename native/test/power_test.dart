import 'dart:io';
import 'dart:isolate';

import 'package:ournet_native/ournet_native.dart';
import 'package:test/test.dart';

void main() {
  test('power and network cost are known on Windows and Linux', () async {
    // As the app asks: on a worker isolate, as Windows goes through COM.
    final state = await Isolate.run(NativePower.state);
    if (Platform.isWindows || Platform.isLinux) {
      expect(state.mains, isNotNull);
    }
    if (Platform.isWindows) expect(state.metered, isNotNull);
    // Called again on this isolate (single-threaded COM here on Flutter).
    expect(NativePower.state().mains, state.mains);
  });
}
