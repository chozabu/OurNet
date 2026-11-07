import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ournet/services/link_previews.dart';
import 'package:ournet_core/ournet_core.dart';

const _tags =
    '<title>Fallback</title>'
    '<meta property="og:title" content="A video">'
    '<meta property="og:description" content="About it">';

void main() {
  late Node node;
  final original = LinkPreviews.publicHost;

  setUp(() async {
    LinkPreviews.publicHost = (_) async => true;
    node = Node(await LocalIdentity.create(label: 'test'), Store());
  });
  tearDown(() => LinkPreviews.publicHost = original);

  /// Previews a page served as [chunks], returning it and how many of the
  /// chunks were asked for.
  Future<(LinkPreview?, int)> fetch(List<String> chunks) async {
    var sent = 0;
    Stream<List<int>> body() async* {
      for (final chunk in chunks) {
        sent++;
        yield latin1.encode(chunk);
      }
    }

    final previews = LinkPreviews(
      node,
      client: () => MockClient.streaming(
        (request, _) async => http.StreamedResponse(
          body(),
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
      ),
    );
    final preview = await previews.preview(
      Uri.parse('https://example.com/watch'),
    );
    return (preview, sent);
  }

  test('finds tags far into a long head, as on YouTube', () async {
    final script = '<script>${'x' * (780 * 1024)}</script>';
    final (preview, _) = await fetch(['<html><head>', script, _tags]);
    expect(preview?.title, 'A video');
    expect(preview?.description, 'About it');
  });

  test('stops reading at the end of the head', () async {
    final (preview, sent) = await fetch([
      '<html><head>$_tags</head>',
      '<body>never needed',
      'nor this',
    ]);
    expect(preview?.title, 'A video');
    expect(sent, 1);
  });

  test('sees the end of the head across two chunks', () async {
    final (preview, sent) = await fetch([
      '<html><head>$_tags</he',
      'ad><body>',
      'never needed',
    ]);
    expect(preview?.title, 'A video');
    expect(sent, 2);
  });

  test('gives up on a head past the limit', () async {
    final filler = 'x' * (1024 * 1024);
    final (preview, sent) = await fetch([
      '<html><head><script>',
      filler,
      filler,
      '</script>$_tags',
    ]);
    expect(preview, isNull);
    expect(sent, 3);
  });
}
