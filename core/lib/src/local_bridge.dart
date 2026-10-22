import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'plugins.dart';

/// Lets programs this person runs on this computer reach plugins granted
/// `local`: `git-remote-ournet` reaching the Git plugin, say. Desktop only.
///
/// It listens on a loopback port and writes the port and a random key to
/// [path] (`~/.ournet/bridge.json` unless given), readable by this person.
/// A request is `POST /plugins/<id>` with `Authorization: Bearer <key>`; its
/// body goes to the plugin's `on-request` from device `local`, and the
/// plugin's answer is the response (400 with its refusal as text). Requests
/// without the key, from another Host (a web page rebinding a name to
/// 127.0.0.1) or bigger than [maxBody] are refused before any plugin sees
/// them. It runs only while some running plugin is granted `local`.
class LocalBridge {
  final Plugins plugins;
  final String path;
  HttpServer? _server;
  String _token = '';
  int _fileTransfers = 0;
  Future<void> _work = Future.value();

  /// Largest request: a plugin's own limits come after.
  static const maxBody = 24 * 1024 * 1024;

  LocalBridge(this.plugins, {String? path}) : path = path ?? defaultPath();

  /// `~/.ournet/bridge.json`, where `git-remote-ournet` looks.
  static String defaultPath() {
    final home =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;
    return '$home${Platform.pathSeparator}.ournet${Platform.pathSeparator}bridge.json';
  }

  /// The port it listens on, while it does.
  int? get port => _server?.port;

  /// Starts it while a plugin takes local requests, and stops it when none
  /// does. Cheap to call on every change.
  Future<void> sync() => _work = _work
      .then((_) async {
        if (plugins.takesLocal) {
          await _start();
        } else {
          await _stop();
        }
      })
      .catchError((Object _) {});

  Future<void> close() => _work = _work.then((_) => _stop());

  Future<void> _start() async {
    if (_server != null) return;
    final random = Random.secure();
    _token = [
      for (var i = 0; i < 32; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((r) => unawaited(_serve(r)));
    final file = File(path);
    await file.parent.create(recursive: true);
    final next = File('$path.next');
    await next.writeAsString('');
    if (!Platform.isWindows) {
      // Before the key is in it: only this person may read it.
      await Process.run('chmod', ['600', next.path]);
    }
    await next.writeAsString(
      jsonEncode({'port': server.port, 'token': _token, 'pid': pid}),
      flush: true,
    );
    await next.rename(path);
  }

  Future<void> _stop() async {
    final server = _server;
    if (server == null) return;
    _server = null;
    await server.close(force: true);
    try {
      // Another instance may have written its own since.
      final file = File(path);
      final written = jsonDecode(await file.readAsString());
      if (written is Map && written['token'] == _token) await file.delete();
    } catch (_) {}
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    Future<void> refuse(int status, String message) async {
      response
        ..statusCode = status
        ..headers.contentType = ContentType.text;
      response.write(message);
      await response.close();
    }

    try {
      final host = request.headers.host;
      if (host != '127.0.0.1' && host != 'localhost') {
        return await refuse(HttpStatus.forbidden, 'Wrong host');
      }
      if (!_matches(request.headers.value('authorization') ?? '')) {
        return await refuse(HttpStatus.unauthorized, 'Wrong key');
      }
      final parts = request.uri.pathSegments;
      // Streaming attachments bypass the bounded JSON request buffer, using
      // transport's encrypted chunk trees and progress/cancellation support.
      if (parts.length >= 3 &&
          parts.first == 'plugins' &&
          parts[2] == 'files') {
        if (_fileTransfers >= 2) {
          return await refuse(
            HttpStatus.serviceUnavailable,
            'Two file transfers are already running; retry shortly',
          );
        }
        _fileTransfers++;
        try {
          if (request.method == 'POST' && parts.length == 3) {
            final handle = await plugins.localStoreFile(
              parts[1],
              request,
              request.contentLength,
            );
            response.headers.contentType = ContentType.json;
            response.write(jsonEncode({'file': handle}));
          } else if (request.method == 'GET' && parts.length == 4) {
            final (size, source) = await plugins.localOpenFile(
              parts[1],
              parts[3],
            );
            response.headers.contentType = ContentType.binary;
            response.contentLength = size;
            await response.addStream(source);
          } else {
            return await refuse(HttpStatus.notFound, 'Not found');
          }
          await response.close();
        } on StateError catch (e) {
          await refuse(HttpStatus.badRequest, e.message);
        } finally {
          _fileTransfers--;
        }
        return;
      }
      if (request.method != 'POST' ||
          parts.length != 2 ||
          parts.first != 'plugins') {
        return await refuse(HttpStatus.notFound, 'Not found');
      }
      final length = request.contentLength;
      if (length > maxBody) {
        return await refuse(HttpStatus.requestEntityTooLarge, 'Too large');
      }
      final body = BytesBuilder(copy: false);
      await for (final chunk in request) {
        body.add(chunk);
        if (body.length > maxBody) {
          return await refuse(HttpStatus.requestEntityTooLarge, 'Too large');
        }
      }
      final Uint8List reply;
      try {
        reply = await plugins.local(parts[1], body.takeBytes());
      } on StateError catch (e) {
        return await refuse(HttpStatus.badRequest, e.message);
      } on TimeoutException {
        return await refuse(
          HttpStatus.gatewayTimeout,
          'The plugin took too long',
        );
      }
      response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.binary
        ..contentLength = reply.length
        ..add(reply);
      await response.close();
    } catch (_) {
      try {
        await refuse(HttpStatus.internalServerError, 'Failed');
      } catch (_) {}
    }
  }

  /// Compares the key in time that does not depend on where it differs.
  bool _matches(String header) {
    final given = utf8.encode(header);
    final wanted = utf8.encode('Bearer $_token');
    var diff = given.length ^ wanted.length;
    for (var i = 0; i < wanted.length; i++) {
      diff |= wanted[i] ^ (i < given.length ? given[i] : 0);
    }
    return _token.isNotEmpty && diff == 0;
  }
}
