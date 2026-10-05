import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';

enum RingSound {
  /// A call is coming in: loud enough to hear across a room.
  incoming,

  /// Our call is ringing on the other side: quiet, as a phone line's is.
  ringback,
}

/// The sounds of a one-to-one call. Tones are synthesised (a few hundred
/// kilobytes, once), so every platform rings the same without assets or
/// access to the system ringtone. On Android the incoming tone plays as a
/// ringtone, so the ringer volume and silent mode apply to it.
class Ringer {
  AudioPlayer? _player;
  RingSound? _wanted;
  Future<void> _applying = Future.value();
  final _tones = <RingSound, Uint8List>{};

  /// Plays [sound] on a loop, or stops when null. Changes are applied in
  /// order, so a quick answer never leaves a tone playing.
  void play(RingSound? sound) {
    if (sound == _wanted) return;
    _wanted = sound;
    _applying = _applying.then((_) => _apply(sound)).catchError((Object _) {});
  }

  Future<void> _apply(RingSound? sound) async {
    final old = _player;
    _player = null;
    if (old != null) {
      await old.stop();
      await old.dispose();
    }
    if (sound == null || sound != _wanted) return;
    final player = AudioPlayer();
    _player = player;
    await player.setAudioContext(
      sound == RingSound.incoming
          ? AudioContext(
              android: const AudioContextAndroid(
                contentType: AndroidContentType.sonification,
                usageType: AndroidUsageType.notificationRingtone,
                audioFocus: AndroidAudioFocus.gainTransient,
                // Keeps a sleeping phone's processor up while it rings.
                stayAwake: true,
              ),
            )
          : AudioContext(
              // The call's own audio session is already set up: share it
              // rather than take focus from the microphone.
              android: const AudioContextAndroid(
                audioMode: AndroidAudioMode.inCommunication,
                contentType: AndroidContentType.sonification,
                usageType: AndroidUsageType.voiceCommunicationSignalling,
                audioFocus: AndroidAudioFocus.none,
              ),
            ),
    );
    await player.setReleaseMode(ReleaseMode.loop);
    // Answered meanwhile: the next change disposes of this player.
    if (sound != _wanted) return;
    await player.play(
      BytesSource(_tones[sound] ??= toneFor(sound), mimeType: 'audio/wav'),
      volume: sound == RingSound.incoming ? 1 : .6,
    );
  }

  Future<void> close() async {
    play(null);
    await _applying;
  }
}

const _rate = 22050;

/// One loop of [sound] as a 16-bit mono WAV file.
Uint8List toneFor(RingSound sound) => switch (sound) {
  // A rising three-note chime, twice, then a pause: 3 s.
  RingSound.incoming => _wav(3, (t) {
    const notes = [659.25, 830.61, 987.77];
    var v = 0.0;
    for (var round = 0; round < 2; round++) {
      for (var i = 0; i < notes.length; i++) {
        final start = round * .6 + i * .15;
        final at = t - start;
        if (at < 0 || at > .5) continue;
        final envelope = min(1.0, at / .006) * exp(-at * 7);
        v +=
            envelope *
            (sin(2 * pi * notes[i] * at) + .3 * sin(4 * pi * notes[i] * at));
      }
    }
    return v * .45;
  }),
  // The UK double ring (400 + 450 Hz; 0.4 s on, 0.2 off, 0.4 on, 2 off).
  RingSound.ringback => _wav(3, (t) {
    final on = t < .4 || (t >= .6 && t < 1);
    if (!on) return 0;
    final local = t < .4 ? t : t - .6;
    final edge = min(1.0, min(local, .4 - local) / .01);
    return edge * .25 * (sin(2 * pi * 400 * t) + sin(2 * pi * 450 * t));
  }),
};

Uint8List _wav(double seconds, double Function(double t) sample) {
  final count = (seconds * _rate).round();
  final bytes = ByteData(44 + count * 2);
  void text(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, 36 + count * 2, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little); // PCM
  bytes.setUint16(22, 1, Endian.little); // mono
  bytes.setUint32(24, _rate, Endian.little);
  bytes.setUint32(28, _rate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, count * 2, Endian.little);
  for (var i = 0; i < count; i++) {
    final v = sample(i / _rate).clamp(-1.0, 1.0);
    bytes.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}
