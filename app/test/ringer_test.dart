import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/ringer.dart';

void main() {
  test('ring tones are short, valid, looping WAV files', () {
    for (final sound in RingSound.values) {
      final wav = toneFor(sound);
      final data = ByteData.sublistView(wav);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(data.getUint32(4, Endian.little), wav.length - 8);
      final rate = data.getUint32(24, Endian.little);
      final seconds = (wav.length - 44) / 2 / rate;
      expect(seconds, closeTo(3, .01));
      // Not silent, and not clipping.
      var peak = 0;
      for (var i = 44; i < wav.length; i += 2) {
        final v = data.getInt16(i, Endian.little).abs();
        if (v > peak) peak = v;
      }
      expect(peak, inInclusiveRange(4000, 32766));
      // A loop starts and ends quietly, so it does not click.
      expect(data.getInt16(44, Endian.little).abs(), lessThan(500));
      expect(data.getInt16(wav.length - 2, Endian.little).abs(), lessThan(500));
    }
  });
}
