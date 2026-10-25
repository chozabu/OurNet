import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

/// `[type][u32 length][body]`, as the capture frames it.
Uint8List frame(int type, List<int> body) {
  final out = ByteData(5 + body.length)
    ..setUint8(0, type)
    ..setUint32(1, body.length, Endian.little);
  final bytes = out.buffer.asUint8List()..setRange(5, 5 + body.length, body);
  return bytes;
}

void main() {
  late Node a, b;
  late PeerNetwork na, nb;

  setUp(() async {
    a = Node(await LocalIdentity.create(), Store());
    b = Node(await LocalIdentity.create(), Store());
    na = PeerNetwork(a);
    nb = PeerNetwork(b);
    await na.start(local: true, automatic: false);
    await nb.start(local: true, automatic: false);
    await Future<void>.delayed(const Duration(seconds: 1));
    await na.addCard(nb.contactCard());
    await nb.addCard(na.contactCard());
  });

  tearDown(() async {
    await na.stop();
    await nb.stop();
    await a.close();
    await b.close();
  });

  test('a desktop stream carries frames out and datagrams back', () async {
    final heard = <List<int>>[];
    final gotDatagram = Completer<void>();
    nb.serveDesktop = (peer, request, stream) async {
      expect(peer, a.identity.device);
      expect(request['plugin'], 'remote-desktop');
      await stream.accept({'v': 1});
      // Frames larger than one read, so the reader joins them.
      for (var i = 0; i < 5; i++) {
        await stream.write(frame(1, List.filled(300 * 1024 + i, i)));
      }
      await stream.write(frame(2, '{"width":4}'.codeUnits));
      final sub = stream.datagrams.listen((d) {
        heard.add(d);
        if (!gotDatagram.isCompleted) gotDatagram.complete();
      });
      await gotDatagram.future.timeout(const Duration(seconds: 10));
      await sub.cancel();
    };
    final viewing = await na.openDesktop(b.identity.device, {
      'plugin': 'remote-desktop',
    });
    expect(viewing.header['ok'], true);
    final frames = <(int, int)>[];
    final sending = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => viewing.datagram([2, 1, 0, 0, 0]),
    );
    await for (final (type, body) in viewing.frames) {
      frames.add((type, body.length));
      if (type == 1) expect(body.every((x) => x == body[0]), isTrue);
    }
    sending.cancel();
    expect(frames, [
      for (var i = 0; i < 5; i++) (1, 300 * 1024 + i),
      (2, 11),
    ]);
    expect(heard.first, [2, 1, 0, 0, 0]);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a refused desktop stream says why, and unserved is unknown', () async {
    await expectLater(
      na.openDesktop(b.identity.device, {'plugin': 'x'}),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', 'Unknown request'),
      ),
    );
    nb.serveDesktop = (peer, request, stream) async =>
        throw StateError('Not allowed here');
    await expectLater(
      na.openDesktop(b.identity.device, {'plugin': 'x'}),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', 'Not allowed here'),
      ),
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  // The real capture, hardware encoder and decoder, over the network
  // between two local nodes. Needs an interactive Windows desktop with a
  // GPU, so it runs only when asked: OURNET_DESKTOP_TEST=1. It sends no
  // input, so it never moves this machine's mouse.
  test(
    'this screen streams and decodes over the network',
    () async {
      final ended = Completer<void>();
      nb.serveDesktop = (peer, request, stream) async {
        final capture = DesktopCapture.start(
          {'fps': 60, 'kbps': 15000, 'width': 1920},
          (message) {
            if (message.isEmpty) {
              if (!ended.isCompleted) ended.complete();
            } else {
              unawaited(stream.write(message));
            }
          },
        )!;
        await stream.accept({'v': 1});
        final sub = stream.datagrams.listen(capture.datagram);
        await Future.any([ended.future, stream.done]);
        capture.stop();
        await sub.cancel();
      };
      final decoder = DesktopDecoder.open()!;
      final viewing = await na.openDesktop(b.identity.device, {
        'plugin': 'remote-desktop',
      });
      var video = 0;
      Map<String, Object?>? info;
      final began = DateTime.now();
      // A still screen sends one picture; ask for it again now and then.
      final poke = Timer.periodic(
        const Duration(milliseconds: 40),
        (_) => viewing.datagram([3]),
      );
      await for (final (type, body) in viewing.frames) {
        if (type == 1) {
          video++;
          decoder.push(body);
          viewing.datagram([2, ...body.sublist(0, 4)]);
        } else if (type == 2) {
          info = {...?info, ...(jsonDecodeMap(body))};
        } else if (type == 3) {
          fail(String.fromCharCodes(body));
        }
        if (DateTime.now().difference(began) > const Duration(seconds: 4)) {
          break;
        }
      }
      poke.cancel();
      viewing.close();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final status = decoder.status;
      decoder.close();
      // ignore: avoid_print
      print('info $info; video $video; decoded ${status.decoded}, '
          'decode ${status.decodeMicros} µs');
      expect(video, greaterThan(10));
      expect(status.decoded, greaterThan(10));
      expect(status.width, info!['width']);
    },
    skip: Platform.environment['OURNET_DESKTOP_TEST'] == '1'
        ? false
        : 'needs an interactive Windows desktop: OURNET_DESKTOP_TEST=1',
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

Map<String, Object?> jsonDecodeMap(Uint8List body) =>
    (const JsonDecoder().convert(String.fromCharCodes(body)) as Map)
        .cast<String, Object?>();
