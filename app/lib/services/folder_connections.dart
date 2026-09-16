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

  @override
  Future<void> readTo(String path, String destination, String expected) async {
    await call('read', {
      'path': path,
      'destination': destination,
      'expected': expected,
    });
  }

  @override
  Future<FolderItem> put(String path, String source, String? expected) async {
    final value = await call<Map>('put', {
      'path': path,
      'source': source,
      'expected': expected,
    });
    if (value == null) {
      throw StateError('Provider did not confirm the written file');
    }
    return item(value);
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
  Future<void> remove(String path, String expected) async {
    await call('remove', {'path': path, 'expected': expected});
  }
}
