import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_speech/ournet_speech.dart';
import 'package:ournet_transport/ournet_transport.dart' show Files;
import 'package:path_provider/path_provider.dart';

import 'live_speech.dart';

/// A whisper.cpp model that can be downloaded once and used offline.
class SpeechModel {
  final String id, label, file, sha256;
  final int size;
  const SpeechModel(this.id, this.label, this.file, this.sha256, this.size);
  String get url =>
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$file';
  String get megabytes => '${(size / 1000000).round()} MB';
}

/// Quantised multilingual models from the whisper.cpp model repository,
/// pinned by SHA-256. A download that does not match is discarded.
const speechModels = [
  SpeechModel(
    'base',
    'Accurate',
    'ggml-base-q5_1.bin',
    '422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898',
    59707625,
  ),
  SpeechModel(
    'tiny',
    'Fast',
    'ggml-tiny-q5_1.bin',
    '818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7',
    32152673,
  ),
];

/// Transcription status of one attachment on this device.
class TranscriptionStatus {
  final String state; // queued, running, failed
  final int progress;
  final String? error;
  const TranscriptionStatus(this.state, {this.progress = 0, this.error});
}

/// Voice-note transcription on this device.
///
/// The system speech engine writes the transcript live while recording
/// (Windows, Android 13+), so a note is ready the moment recording stops. It
/// is the default only where audio stays private or the person has already
/// agreed to the provider: the phone's on-device recognizer, or Windows with
/// online speech recognition turned on. Otherwise Whisper runs locally after
/// recording, and the system engine is an explicit choice. Jobs are durable
/// settings, so a transcription interrupted by the app closing resumes on
/// next start. Only the device that recorded a note transcribes it
/// automatically.
class Speech extends ChangeNotifier {
  final Notes notes;
  final Files files;
  final MethodChannel channel;
  Speech(
    this.notes,
    this.files, {
    this.channel = const MethodChannel('ournet/speech'),
  });

  Node get node => notes.node;
  final status = <String, TranscriptionStatus>{};
  final _queue = Queue<(String, String, bool)>();
  bool _running = false, _closed = false;
  TranscriptionCancel? _cancel;
  String? _downloading;
  double downloadProgress = 0;
  HttpClient? _http;
  Directory? _models;

  /// `system`, `whisper` or `off`. Unchosen, [defaultEngine] applies.
  String get engine =>
      node.store.setting('speech/engine') as String? ?? defaultEngine;

  /// System speech when it is private or already agreed to, else Whisper.
  String get defaultEngine => liveDefault ? 'system' : 'whisper';

  /// Whether a person has picked an engine, rather than the default.
  bool get engineChosen => node.store.setting('speech/engine') != null;
  set engine(String value) {
    node.store.set('speech/engine', value);
    notifyListeners();
    _pump();
  }

  String get modelId => node.store.setting('speech/model') as String? ?? 'base';
  set modelId(String value) {
    node.store.set('speech/model', value);
    notifyListeners();
  }

  /// A language code such as `en`, or `auto`.
  String get language =>
      node.store.setting('speech/language') as String? ?? 'auto';
  set language(String value) {
    node.store.set('speech/language', value);
    notifyListeners();
    unawaited(checkLive());
  }

  SpeechModel get model => speechModels.firstWhere(
    (m) => m.id == modelId,
    orElse: () => speechModels.first,
  );
  String? get downloading => _downloading;

  Future<Directory> _modelDirectory() async => _models ??= Directory(
    '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}speech',
  )..createSync(recursive: true);

  Future<File> modelFile(SpeechModel model) async => File(
    '${(await _modelDirectory()).path}${Platform.pathSeparator}${model.file}',
  );

  /// Whether [model] has been downloaded and verified on this device.
  Future<bool> installed(SpeechModel model) async =>
      node.store.setting('speech/verified/${model.id}') == true &&
      await (await modelFile(model)).exists();

  /// Whether the system service can transcribe an existing recording.
  bool get systemAvailable => _systemAvailable ?? false;
  bool? _systemAvailable;

  /// Whether the system service can transcribe while recording.
  bool get liveAvailable => _live?['available'] == true;

  /// Whether live audio stays on this device (Android's on-device recognizer).
  bool get liveOnDevice => _live?['onDevice'] == true;

  /// Whether Windows online speech recognition is turned on, which dictation
  /// needs and which means the person has agreed to Microsoft's terms.
  bool get liveAllowed => _live?['allowed'] == true;

  /// Whether live system speech may be used without asking first.
  bool get liveDefault =>
      liveAvailable && (Platform.isWindows ? liveAllowed : liveOnDevice);
  Map<Object?, Object?>? _live;

  /// For tests: audio that live recordings use in place of the microphone.
  @visibleForTesting
  String? liveSource;

  /// Rechecks live system speech, e.g. after settings changed outside the app.
  Future<void> checkLive() async {
    if (!Platform.isAndroid && !Platform.isWindows) return;
    try {
      _live = await channel.invokeMapMethod('liveStatus', {
        'language': language,
      });
    } catch (_) {
      _live = null;
    }
    notifyListeners();
  }

  /// Checks platform support for the system speech engine.
  Future<void> start() async {
    if (Platform.isAndroid) {
      try {
        _systemAvailable =
            await channel.invokeMethod<bool>('available') ?? false;
      } catch (_) {
        _systemAvailable = false;
      }
    }
    await checkLive();
    for (final job
        in (node.store.setting('speech/jobs') as List? ?? const [])) {
      final [note, file, ...rest] = (job as List).cast<Object>();
      _enqueue(
        note as String,
        file as String,
        persist: false,
        replace: rest.firstOrNull == true,
      );
    }
    await _cleanTemporary();
    notifyListeners();
    _pump();
  }

  bool get ready => engine != 'off';

  /// Whether queued transcriptions use Whisper. The system engine falls back
  /// to it where the platform only offers live recognition (Windows).
  bool get usesWhisper =>
      engine == 'whisper' || (engine == 'system' && !systemAvailable);

  /// A live transcription for the next recording, when the system engine is
  /// in use and can listen live here. On Android the on-device recognizer is
  /// used when it has the language; otherwise the speech service, which the
  /// person chose knowingly.
  LiveSpeech? live() => engine == 'system' && liveAvailable
      ? LiveSpeech(
          language: _live?['locale'] as String? ?? language,
          engine: liveOnDevice ? 'device' : 'cloud',
          source: liveSource,
          channel: channel,
        )
      : null;

  /// Saves text recognised live while recording, keeping any writing already
  /// in the transcript.
  Future<void> saveTranscript(String note, String file, String text) =>
      _save(note, file, text, replace: false);

  /// Downloads and verifies the selected model. Cancels with [cancelDownload].
  Future<void> download(SpeechModel model) async {
    if (_downloading != null) return;
    _downloading = model.id;
    downloadProgress = 0;
    notifyListeners();
    final target = await modelFile(model);
    final part = File('${target.path}.part');
    final http = _http = HttpClient();
    try {
      final request = await http.getUrl(Uri.parse(model.url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw StateError('Download failed (${response.statusCode}).');
      }
      final sink = part.openWrite();
      final digest = _DigestSink();
      final hashing = sha256.startChunkedConversion(digest);
      var received = 0;
      try {
        await for (final chunk in response) {
          received += chunk.length;
          if (received > model.size) throw StateError('Unexpected model size.');
          hashing.add(chunk);
          sink.add(chunk);
          downloadProgress = received / model.size;
          notifyListeners();
        }
      } finally {
        await sink.close();
        hashing.close();
      }
      if (received != model.size || digest.value.toString() != model.sha256) {
        throw StateError('The downloaded model did not match. Try again.');
      }
      await part.rename(target.path);
      node.store.set('speech/verified/${model.id}', true);
    } catch (_) {
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      http.close(force: true);
      _http = null;
      _downloading = null;
      notifyListeners();
      _pump();
    }
  }

  void cancelDownload() => _http?.close(force: true);

  Future<void> removeModel(SpeechModel model) async {
    node.store.set('speech/verified/${model.id}', false);
    final file = await modelFile(model);
    if (await file.exists()) await file.delete();
    notifyListeners();
  }

  /// Queues transcription of an audio attachment. An automatic transcription
  /// never replaces writing; [replace] (an explicit request) does.
  void transcribe(String note, String file, {bool replace = false}) =>
      _enqueue(note, file, replace: replace);

  void _enqueue(
    String note,
    String file, {
    bool persist = true,
    bool replace = false,
  }) {
    if (_queue.any((j) => j.$2 == file) || status[file]?.state == 'running') {
      return;
    }
    _queue.add((note, file, replace));
    status[file] = const TranscriptionStatus('queued');
    if (persist) _persist();
    notifyListeners();
    _pump();
  }

  void cancel(String file) {
    _queue.removeWhere((j) => j.$2 == file);
    if (status[file]?.state == 'running') _cancel?.cancel();
    status.remove(file);
    _persist();
    notifyListeners();
  }

  void _persist() => node.store.set('speech/jobs', [
    if (_current case (final note, final file, final replace))
      [note, file, replace],
    for (final (note, file, replace) in _queue) [note, file, replace],
  ]);

  (String, String, bool)? _current;

  /// Serialises transcriptions so two models never run at once.
  Future<void> _exclusive = Future.value();
  Future<T> _one<T>(Future<T> Function() run) {
    final result = _exclusive.then((_) => run());
    _exclusive = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Whether a recording can be transcribed now without downloading a model.
  Future<bool> canTranscribe() async =>
      ready && (!usesWhisper || await installed(model));

  /// Transcribes an audio file outside any note, such as a voice message
  /// before it is sent. [onProgress] reports Whisper's percentage.
  Future<String> transcribeFile(
    String path, {
    void Function(int progress)? onProgress,
  }) => _one(() async {
    if (!await canTranscribe()) {
      throw StateError('Transcription is not set up on this device.');
    }
    return (await _transcribe(path, onProgress: onProgress)).trim();
  });

  Future<void> _pump() async {
    if (_running || _closed || _queue.isEmpty || !ready) return;
    if (usesWhisper && !await installed(model)) return;
    _running = true;
    try {
      while (_queue.isNotEmpty && !_closed && ready) {
        final job = _queue.removeFirst();
        _current = job;
        _persist();
        final (note, file, replace) = job;
        try {
          status[file] = const TranscriptionStatus('running');
          notifyListeners();
          final text = await _one(() => _run(note, file));
          await _save(note, file, text, replace: replace);
          status.remove(file);
        } catch (e) {
          status[file] = TranscriptionStatus('failed', error: '$e');
        } finally {
          _current = null;
          _persist();
          notifyListeners();
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<String> _run(String noteId, String file) async {
    final note = await notes.get(noteId);
    final op = note?.file(file);
    if (note == null || op == null) {
      throw StateError('The recording is unavailable.');
    }
    final bytes = await files.readBytes(op.object, limit: Notes.maxFileSize);
    final temp = Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}ournet-speech',
    )..createSync(recursive: true);
    final audio = File(
      '${temp.path}${Platform.pathSeparator}${randomId().replaceAll(RegExp('[^A-Za-z0-9]'), '')}.${_extension(op.data['name'])}',
    );
    // The decoder needs a file. It is deleted as soon as decoding finishes,
    // and any left behind by an interrupted run is removed at start-up.
    await audio.writeAsBytes(bytes, flush: true);
    try {
      return await _transcribe(
        audio.path,
        onProgress: (p) {
          status[file] = TranscriptionStatus('running', progress: p);
          notifyListeners();
        },
      );
    } finally {
      if (await audio.exists()) await audio.delete();
    }
  }

  Future<String> _transcribe(
    String path, {
    void Function(int progress)? onProgress,
  }) async {
    final audio = File(path);
    try {
      if (!usesWhisper) {
        final pcm = File('${audio.path}.pcm');
        try {
          await Whisper.decodePcm16(audio.path, pcm.path);
          return await channel.invokeMethod<String>('transcribe', {
                'path': pcm.path,
                'language': language,
              }) ??
              '';
        } finally {
          if (await pcm.exists()) await pcm.delete();
        }
      }
      final cancel = _cancel = TranscriptionCancel();
      return await Whisper.transcribe(
        audioPath: audio.path,
        modelPath: (await modelFile(model)).path,
        language: language,
        cancel: cancel,
        onProgress: onProgress,
      );
    } finally {
      _cancel = null;
    }
  }

  static String _extension(Object? name) {
    final match = RegExp(r'\.([A-Za-z0-9]{1,5})$').firstMatch('$name');
    return match?.group(1) ?? 'm4a';
  }

  /// Saves the transcript. Automatic runs keep any writing already there.
  Future<void> _save(
    String noteId,
    String file,
    String text, {
    required bool replace,
  }) async {
    final note = await notes.get(noteId);
    if (note == null) return;
    final existing = note.transcript(file).trim();
    final value = text.trim();
    if (value.isEmpty || existing == value) return;
    if (existing.isNotEmpty && !replace) return;
    await notes.set(note, 'file:$file:transcript', value);
  }

  Future<void> _cleanTemporary() async {
    try {
      final temp = Directory(
        '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}ournet-speech',
      );
      if (await temp.exists()) await temp.delete(recursive: true);
    } catch (_) {
      /* Best effort; files are removed after each job as well. */
    }
  }

  void close() {
    _closed = true;
    _cancel?.cancel();
    _http?.close(force: true);
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
