import 'dart:io';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ournet_transport/ournet_transport.dart';

const _channel = MethodChannel('ournet/folders');
Future<String?> pickSyncFolder() async => Platform.isAndroid
    ? await _channel.invokeMethod<String>('pick')
    : await FilePicker.getDirectoryPath(dialogTitle: 'Choose a folder to sync');
FolderBackend folderBackend(String location) => location.startsWith('content:')
    ? AndroidFolderBackend(location)
    : DiskFolderBackend(location);

class AndroidFolderBackend extends FolderBackend {
  @override
  final String location;
  AndroidFolderBackend(this.location);
  Future<T?> call<T>(String method, [Map<String, dynamic> args = const {}]) =>
      _channel.invokeMethod<T>(method, {'tree': location, ...args});
  FolderItem item(Map value) => FolderItem(
    value['directory'] as bool,
    value['token'] as String,
    (value['size'] as num?)?.toInt() ?? 0,
    null,
    switch (value['modified']) {
      final num ms when ms > 0 => DateTime.fromMillisecondsSinceEpoch(
        ms.toInt(),
      ),
      _ => null,
    },
  );
  @override
  Future<Map<String, FolderItem>> scan() async {
    final values = await call<Map>('scan');
    if (values == null) throw StateError('Folder unavailable');
    return {
      for (final entry in values.entries)
        entry.key as String: item(entry.value as Map),
    };
  }

  @override
  Future<FolderItem?> stat(String path) async {
    final value = await call<Map>('stat', {'path': path});
    return value == null ? null : item(value);
  }

  /// Read through a handle a chunk at a time; the provider checks the
  /// token when the read opens and again once it has ended.
  @override
  Stream<List<int>> read(String path, String expected) async* {
    final handle = await call<int>('readOpen', {
      'path': path,
      'expected': expected,
    });
    var ended = false;
    try {
      while (true) {
        final bytes = await call<Uint8List>('readNext', {'handle': handle});
        if (bytes == null) break;
        yield bytes;
      }
      ended = true;
      await call('readEnd', {
        'handle': handle,
        'path': path,
        'expected': expected,
      });
    } finally {
      if (!ended) {
        await call('readClose', {'handle': handle}).catchError((_) => null);
      }
    }
  }

  /// Written a chunk at a time into a temporary document beside [path],
  /// which replaces it on commit only if its token is still [expected].
  @override
  Future<FolderItem> write(
    String path,
    Stream<List<int>> data,
    String? expected,
  ) async {
    final handle = await call<int>('writeOpen', {'path': path});
    var committed = false;
    try {
      await for (final bytes in data) {
        await call('writeNext', {
          'handle': handle,
          'bytes': bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        });
      }
      final value = await call<Map>('writeCommit', {
        'handle': handle,
        'path': path,
        'expected': expected,
      });
      committed = true;
      if (value == null) {
        throw StateError('Provider did not confirm the written file');
      }
      return item(value);
    } finally {
      if (!committed) {
        await call('writeAbort', {'handle': handle}).catchError((_) => null);
      }
    }
  }

  @override
  Future<Uint8List> readRange(
    String path,
    int offset,
    int length,
    String expected,
  ) async {
    final bytes = await call<Uint8List>('readRange', {
      'path': path,
      'expected': expected,
      'offset': offset,
      'length': length,
    });
    if (bytes == null || bytes.length != length) {
      throw StateError('File changed: $path');
    }
    return bytes;
  }

  @override
  Future<void> mkdir(String path) async {
    await call('mkdir', {'path': path});
  }

  @override
  Future<void> move(String source, String destination, String expected) async {
    await call('move', {
      'path': source,
      'destination': destination,
      'expected': expected,
    });
  }

  @override
  Future<String> setAside(String path, String expected) async =>
      await call<String>('aside', {'path': path, 'expected': expected}) ??
      'the synced folder';

  @override
  Future<void> remove(String path, String expected) async {
    await call('remove', {'path': path, 'expected': expected});
  }
}
