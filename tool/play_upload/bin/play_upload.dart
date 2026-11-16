// Uploads an Android App Bundle to a Google Play track and rolls it out.
//
// dart run bin/play_upload.dart --key service-account.json --bundle app.aab
//   [--package org.chozabu.ournet] [--track internal] [--notes "What changed"] [--no-review]
import 'dart:io';

import 'package:googleapis/androidpublisher/v3.dart';
import 'package:googleapis_auth/auth_io.dart';

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  var noReview = false;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--no-review') {
      noReview = true;
      continue;
    }
    if (!args[i].startsWith('--') || i + 1 >= args.length) break;
    options[args[i].substring(2)] = args[++i];
  }
  final key = options['key'];
  final bundlePath = options['bundle'];
  if (key == null || bundlePath == null) {
    stderr.writeln('Usage: play_upload --key FILE --bundle FILE [--package ID] [--track NAME] [--notes TEXT] [--no-review]');
    exit(64);
  }
  final packageName = options['package'] ?? 'org.chozabu.ournet';
  final track = options['track'] ?? 'internal';
  final bundle = File(bundlePath);

  final credentials = ServiceAccountCredentials.fromJson(await File(key).readAsString());
  final client = await clientViaServiceAccount(credentials, [AndroidPublisherApi.androidpublisherScope]);
  try {
    final api = AndroidPublisherApi(client);
    final edit = await api.edits.insert(AppEdit(), packageName);
    final editId = edit.id!;
    stdout.writeln('Uploading ${bundle.path} (${(await bundle.length()) ~/ (1024 * 1024)} MB)...');
    final uploaded = await api.edits.bundles.upload(
      packageName,
      editId,
      uploadMedia: Media(bundle.openRead(), await bundle.length(), contentType: 'application/octet-stream'),
      uploadOptions: ResumableUploadOptions(),
    );
    final versionCode = uploaded.versionCode!;
    final notes = options['notes'];
    await api.edits.tracks.update(
      Track(track: track, releases: [
        TrackRelease(
          versionCodes: ['$versionCode'],
          status: 'completed',
          releaseNotes: notes == null ? null : [LocalizedText(language: 'en-GB', text: notes)],
        ),
      ]),
      packageName,
      editId,
      track,
    );
    // With --no-review Play holds the edit until someone presses 'Send changes
    // for review' in Play Console.
    await api.edits.commit(packageName, editId, changesNotSentForReview: noReview ? true : null);
    stdout.writeln(noReview
        ? 'Committed version code $versionCode to the $track track; send it for review in Play Console.'
        : 'Released version code $versionCode to the $track track.');
  } finally {
    client.close();
  }
}
