import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// No stored preview exists and one cannot be generated right now.
class ThumbnailUnavailable implements Exception {
  const ThumbnailUnavailable();
}

/// Durable, encrypted list previews for image attachments.
///
/// Lists display small stored previews instead of reading, decrypting and
/// decoding originals. A missing preview is generated once, one at a time, by
/// a downsampling engine decode; the worker compresses, encrypts and stores
/// it. Decoded images live only in Flutter's bounded [ImageCache].
class Thumbnails {
  static final _instances = Expando<Thumbnails>();
  static Thumbnails of(Files files) =>
      _instances[files.node] ??= Thumbnails._(files);
  Thumbnails._(this.files);

  // List cards show photos at most ~460 physical pixels tall, so a 640 px
  // edge keeps them sharp while decode, read-back and compression cost less
  // than half of the earlier 960 px previews, which are still used if stored.
  static const variant = 'list640';
  static const legacyVariant = 'list960';
  static const maxEdge = 640;

  Future<Uint8List?> _stored(SignedObject object) async =>
      await files.readPreview(object, variant) ??
      await files.readPreview(object, legacyVariant);

  /// Originals above this size need an explicit tap before their first preview.
  static const automaticLimit = 32 * 1024 * 1024;
  static const _maxWaiting = 256;

  final Files files;
  final _jobs = <String, _Job>{};
  final _foreground = ListQueue<_Job>();
  final _background = ListQueue<_Job>();
  final _interest = <String, int>{};
  final _failed = <String>{};
  int _active = 0, _storing = 0;
  Future<void> _delivery = Future.value(), _stores = Future.value();

  /// Resolves after the next frame, or at once when no frame is coming.
  @visibleForTesting
  static Future<void> Function() nextFrame = () async {
    final scheduler = SchedulerBinding.instance;
    if (scheduler.hasScheduledFrame) await scheduler.endOfFrame;
  };
  static Future<void> _nextFrame() => nextFrame();
  static const _concurrency = 2, _maxStoring = 2;

  /// Test and diagnostics counters. No content or identifiers are retained.
  /// `skipped` counts requests deferred because their row scrolled away.
  int generated = 0, skipped = 0;

  /// Widgets register interest so work for rows scrolled away can be skipped.
  void want(String id) => _interest[id] = (_interest[id] ?? 0) + 1;
  void release(String id) {
    final count = (_interest[id] ?? 1) - 1;
    if (count <= 0) {
      _interest.remove(id);
    } else {
      _interest[id] = count;
    }
  }

  void retry(String id) => _failed.remove(id);

  /// A decoded preview: stored bytes when present, else freshly generated.
  /// Generated images are shown immediately while storage finishes.
  Future<({Uint8List? bytes, ui.Image? image})> load(
    SignedObject object, {
    required bool generate,
    int limit = automaticLimit,
  }) async {
    final stored = await _stored(object);
    if (stored != null) return (bytes: stored, image: null);
    if (!generate || _failed.contains(object.id)) {
      throw const ThumbnailUnavailable();
    }
    final image = await _schedule(object, limit, background: false).future;
    // Each consumer owns a handle; the job disposes its own after storing.
    return (bytes: null, image: image.clone());
  }

  /// Prepare a preview ahead of display, e.g. after import or sync.
  Future<void> prepare(SignedObject object) async {
    if (await _stored(object) != null) return;
    await _schedule(object, automaticLimit, background: true).stored.future;
  }

  _Job _schedule(SignedObject object, int limit, {required bool background}) {
    final id = object.id;
    final existing = _jobs[id];
    if (existing != null) return existing;
    final job = _Job(object, limit, background);
    final queue = background ? _background : _foreground;
    if (queue.length >= _maxWaiting) {
      // Drop the oldest request; it has most likely scrolled away.
      final dropped = background ? queue.removeFirst() : queue.removeLast();
      _jobs.remove(dropped.object.id);
      dropped.fail(const ThumbnailUnavailable());
    }
    // Most recently requested rows are the ones on screen.
    background ? queue.addLast(job) : queue.addFirst(job);
    _jobs[id] = job;
    _pump();
    return job;
  }

  void _pump() {
    while (_active < _concurrency) {
      // Rows scrolled away before their turn yield to visible rows, but are
      // still prepared in the background so a later visit is instant.
      while (_foreground.isNotEmpty &&
          (_interest[_foreground.first.object.id] ?? 0) == 0) {
        final job = _foreground.removeFirst()..background = true;
        _background.addLast(job);
        skipped++;
      }
      if (_background.length > _maxWaiting) {
        final dropped = _background.removeFirst();
        _jobs.remove(dropped.object.id);
        dropped.fail(const ThumbnailUnavailable());
      }
      final job = _foreground.isNotEmpty
          ? _foreground.removeFirst()
          : _background.isNotEmpty
          ? _background.removeFirst()
          : null;
      if (job == null) return;
      _active++;
      unawaited(_run(job));
    }
  }

  Future<void> _run(_Job job) async {
    final id = job.object.id;
    ui.Image? image;
    var released = false, storing = false;
    void release() {
      if (released) return;
      released = true;
      _active--;
      _pump();
    }

    try {
      image = await _decode(job.object, job.limit);
      // Previews decoded together would upload in the same frame; hand them
      // to the screen one frame apart.
      final turn = _delivery.then((_) => _nextFrame());
      _delivery = turn;
      await turn;
      job.result.complete(image);
      // The preview is on screen; storing it (compression, encryption) need
      // not hold up the next visible row. A bounded number of stores wait.
      _storing++;
      storing = true;
      if (_storing <= _maxStoring) release();
      final decoded = image;
      // Stores run one at a time, each after a pause in scrolling: reading
      // pixels back competes with the raster thread, and overlapping copies
      // and compression stall the UI isolate on slow phones.
      final store = _stores.then((_) async {
        await quiet();
        final pixels = await decoded.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        if (pixels == null) throw StateError('Image could not be read');
        await files.storePreview(
          job.object,
          variant,
          pixels.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes),
          decoded.width,
          decoded.height,
        );
      });
      _stores = store.catchError((Object _) {});
      await store;
      generated++;
      job.stored.complete();
    } catch (error, stack) {
      // Only undecodable images are remembered; a storage failure retries later.
      if (error is! ThumbnailUnavailable && !job.result.isCompleted) {
        _failed.add(id);
        if (_failed.length > 1024) _failed.remove(_failed.first);
      }
      job.fail(error, stack);
    } finally {
      if (storing) _storing--;
      // Remove before disposing so no new consumer clones a disposed image.
      _jobs.remove(id);
      image?.dispose();
      if (released) {
        _pump();
      } else {
        release();
      }
    }
  }

  /// Waits for a pause in frames before GPU read-back. Widget tests with a
  /// fake clock replace it; device performance tests keep the real wait.
  @visibleForTesting
  static Future<void> Function() quiet = _quiet;

  static Future<void> _quiet() async {
    final scheduler = SchedulerBinding.instance;
    var calm = 0;
    for (var i = 0; i < 100 && calm < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final busy =
          scheduler.hasScheduledFrame || scheduler.transientCallbackCount > 0;
      calm = busy ? 0 : calm + 1;
    }
  }

  Future<ui.Image> _decode(SignedObject object, int limit) async {
    final original = await files.readBytes(object, limit: limit);
    final codec = await PaintingBinding.instance.instantiateImageCodecWithSize(
      await ui.ImmutableBuffer.fromUint8List(original),
      getTargetSize: (width, height) {
        final scale = math.min(1.0, maxEdge / math.max(width, height));
        return ui.TargetImageSize(
          width: math.max(1, (width * scale).round()),
          height: math.max(1, (height * scale).round()),
        );
      },
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }
}

class _Job {
  final SignedObject object;
  final int limit;
  bool background;
  final result = Completer<ui.Image>();
  final stored = Completer<void>();
  _Job(this.object, this.limit, this.background) {
    // Callers may drop interest; unobserved failures must not become errors.
    result.future.ignore();
    stored.future.ignore();
  }
  Future<ui.Image> get future => result.future;
  void fail(Object error, [StackTrace? stack]) {
    if (!result.isCompleted) result.completeError(error, stack);
    if (!stored.isCompleted) stored.completeError(error, stack);
  }
}

/// Stable image identity: the same object shares one decoded cache entry
/// however often its row widget is recreated.
@immutable
class ThumbnailKey {
  final String object;
  const ThumbnailKey(this.object);
  @override
  bool operator ==(Object other) =>
      other is ThumbnailKey && other.object == object;
  @override
  int get hashCode => Object.hash(ThumbnailKey, object);
}

class ThumbnailImage extends ImageProvider<ThumbnailKey> {
  final Thumbnails thumbnails;
  final SignedObject object;
  final bool generate;
  final int limit;
  final int attempt;
  const ThumbnailImage(
    this.thumbnails,
    this.object, {
    required this.generate,
    this.limit = Thumbnails.automaticLimit,
    this.attempt = 0,
  });

  @override
  Future<ThumbnailKey> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(ThumbnailKey(object.id));

  @override
  ImageStreamCompleter loadImage(
    ThumbnailKey key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(_load(decode));

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final result = await thumbnails.load(
      object,
      generate: generate,
      limit: limit,
    );
    if (result.image case final image?) {
      return ImageInfo(image: image, debugLabel: 'thumbnail');
    }
    final codec = await decode(
      await ui.ImmutableBuffer.fromUint8List(result.bytes!),
    );
    try {
      final frame = await codec.getNextFrame();
      return ImageInfo(image: frame.image, debugLabel: 'thumbnail');
    } finally {
      codec.dispose();
    }
  }

  // Availability changes must re-resolve; the cache key stays the object.
  @override
  bool operator ==(Object other) =>
      other is ThumbnailImage &&
      other.object.id == object.id &&
      other.generate == generate &&
      other.limit == limit &&
      other.attempt == attempt;
  @override
  int get hashCode => Object.hash(object.id, generate, limit, attempt);
}
