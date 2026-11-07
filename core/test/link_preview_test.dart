import 'dart:convert';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  final jpeg = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);

  test('round-trips through a payload', () {
    final preview = LinkPreview(
      url: Uri.parse('https://www.example.com/a?b=1'),
      title: 'A page',
      description: 'About things',
      site: 'Example',
      image: jpeg,
    );
    final back = LinkPreview.of({
      'text': 'look https://www.example.com/a?b=1 !',
      'link': jsonDecode(jsonEncode(preview.toJson())),
    }, 'look https://www.example.com/a?b=1 !')!;
    expect(back.url, preview.url);
    expect(back.title, 'A page');
    expect(back.description, 'About things');
    expect(back.site, 'Example');
    expect(back.image, jpeg);
    expect(back.host, 'example.com');
  });

  test('is only shown while its link is in the text', () {
    final payload = {
      'link': {'url': 'https://example.com/x', 'title': 'X'},
    };
    expect(LinkPreview.of(payload, 'see https://example.com/x'), isNotNull);
    expect(LinkPreview.of(payload, 'see example.com/x'), isNotNull);
    expect(LinkPreview.of(payload, 'edited away'), isNull);
    expect(LinkPreview.of(payload, 'see https://evil.example/x'), isNull);
  });

  test('refuses other schemes, credentials and empty previews', () {
    for (final url in [
      'javascript:alert(1)',
      'ournet://chat/x',
      'file:///etc/passwd',
      'https://user:pw@example.com/',
      'https://',
    ]) {
      expect(LinkPreview.fromJson({'url': url, 'title': 'T'}), isNull);
    }
    expect(LinkPreview.fromJson({'url': 'https://example.com/'}), isNull);
    expect(LinkPreview.fromJson('nope'), isNull);
  });

  test('refuses oversized text and drops unusable images', () {
    expect(
      LinkPreview.fromJson({
        'url': 'https://example.com/',
        'title': 'x' * (LinkPreview.maxTitle * 2 + 1),
      }),
      isNull,
    );
    final big = LinkPreview.fromJson({
      'url': 'https://example.com/',
      'title': 'T',
      'image': base64Encode(
        Uint8List(LinkPreview.maxImageBytes + 1)..setAll(0, jpeg),
      ),
    })!;
    expect(big.image, isNull);
    final notImage = LinkPreview.fromJson({
      'url': 'https://example.com/',
      'title': 'T',
      'image': base64Encode(utf8.encode('<svg onload=x>')),
    })!;
    expect(notImage.image, isNull);
    final broken = LinkPreview.fromJson({
      'url': 'https://example.com/',
      'title': 'T',
      'image': '%%%',
    })!;
    expect(broken.image, isNull);
  });

  test('cleans text', () {
    expect(LinkPreview.clean('  a\n\t b\u0000 ', 10), 'a b');
    expect(LinkPreview.clean('abcdefghijk', 5), 'abcd…');
    expect(LinkPreview.clean('   ', 5), isNull);
  });
}
