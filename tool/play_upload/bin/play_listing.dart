// Shows or updates the Google Play store listing: its text and phone
// screenshots.
//
// dart run bin/play_listing.dart --key service-account.json
//   [--language en-GB] [--screenshots DIR] [--short TEXT]
//   [--description FILE] [--dry true]
//
// With only --key it prints the current listings. --screenshots replaces the
// phone screenshots with DIR/*.png in name order; --short and --description
// replace that text. Nothing changes unless something is given, and --dry
// prints what would change without committing.
import 'dart:io';

import 'package:googleapis/androidpublisher/v3.dart';
import 'package:googleapis_auth/auth_io.dart';

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    if (!args[i].startsWith('--')) break;
    options[args[i].substring(2)] = args[i + 1];
  }
  final key = options['key'];
  if (key == null) {
    stderr.writeln(
      'Usage: play_listing --key FILE [--language CODE] [--screenshots DIR] '
      '[--short TEXT] [--description FILE] [--dry true]',
    );
    exit(64);
  }
  const packageName = 'org.chozabu.ournet';
  final dry = options['dry'] == 'true';
  final credentials = ServiceAccountCredentials.fromJson(
    await File(key).readAsString(),
  );
  final client = await clientViaServiceAccount(credentials, [
    AndroidPublisherApi.androidpublisherScope,
  ]);
  try {
    final api = AndroidPublisherApi(client);
    final edit = await api.edits.insert(AppEdit(), packageName);
    final editId = edit.id!;
    final listings = await api.edits.listings.list(packageName, editId);
    final language =
        options['language'] ?? listings.listings?.first.language ?? 'en-GB';
    var changed = false;

    final listing = listings.listings?.firstWhere(
      (l) => l.language == language,
      orElse: () => Listing(language: language),
    );
    final short = options['short'];
    final description = options['description'];
    if (short != null || description != null) {
      final updated = Listing(
        language: language,
        title: listing?.title,
        shortDescription: short ?? listing?.shortDescription,
        fullDescription: description == null
            ? listing?.fullDescription
            : (await File(description).readAsString()).trim(),
        video: listing?.video,
      );
      stdout.writeln(
        'Listing $language: short ${updated.shortDescription!.length} chars, '
        'full ${updated.fullDescription!.length} chars',
      );
      if (updated.shortDescription!.length > 80 ||
          updated.fullDescription!.length > 4000) {
        stderr.writeln('Too long: short is at most 80, full at most 4000.');
        exit(65);
      }
      await api.edits.listings.update(updated, packageName, editId, language);
      changed = true;
    }

    final shots = options['screenshots'];
    if (shots != null) {
      final files =
          Directory(shots)
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.png'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      if (files.isEmpty || files.length > 8) {
        stderr.writeln(
          'Play takes 1 to 8 phone screenshots; found ${files.length}.',
        );
        exit(65);
      }
      await api.edits.images.deleteall(
        packageName,
        editId,
        language,
        'phoneScreenshots',
      );
      for (final f in files) {
        await api.edits.images.upload(
          packageName,
          editId,
          language,
          'phoneScreenshots',
          uploadMedia: Media(
            f.openRead(),
            f.lengthSync(),
            contentType: 'image/png',
          ),
        );
        stdout.writeln('Uploaded ${f.path}');
      }
      changed = true;
    }

    if (!changed) {
      for (final l in listings.listings ?? <Listing>[]) {
        stdout.writeln('== ${l.language}: ${l.title}');
        stdout.writeln('Short: ${l.shortDescription}');
        stdout.writeln('Full:\n${l.fullDescription}\n');
        final images = await api.edits.images.list(
          packageName,
          editId,
          l.language!,
          'phoneScreenshots',
        );
        stdout.writeln('Phone screenshots: ${images.images?.length ?? 0}');
      }
      await api.edits.delete(packageName, editId);
    } else if (dry) {
      await api.edits.validate(packageName, editId);
      await api.edits.delete(packageName, editId);
      stdout.writeln('Dry run: validated, nothing committed.');
    } else {
      await api.edits.commit(packageName, editId);
      stdout.writeln('Committed the listing edit.');
    }
  } finally {
    client.close();
  }
}
