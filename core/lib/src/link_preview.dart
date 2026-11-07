import 'dart:convert';
import 'dart:typed_data';

import 'model.dart';

/// A preview of a web link, made by the sender of a message and carried in
/// its payload as `link`, so the people it goes to never contact the site
/// unless they open the link. Builds without it ignore the field.
///
/// Everything but [url] is the sender's word: whoever shows a preview names
/// the site by [host], taken from [url], and only shows it while [url] is
/// still in the message text.
class LinkPreview {
  static const maxUrl = 2048;
  static const maxTitle = 200;
  static const maxDescription = 300;
  static const maxSite = 80;

  /// Encoded image size limit; a 320 pixel JPEG is usually 8–20 KB.
  static const maxImageBytes = 24 * 1024;

  /// Pixels along the longer side of [image].
  static const imageEdge = 320;

  final Uri url;
  final String? title;
  final String? description;
  final String? site;

  /// A JPEG or PNG, at most [maxImageBytes].
  final Uint8List? image;

  const LinkPreview({
    required this.url,
    this.title,
    this.description,
    this.site,
    this.image,
  });

  /// The host the link really goes to, without a leading `www.`.
  String get host {
    final h = url.host.toLowerCase();
    return h.startsWith('www.') ? h.substring(4) : h;
  }

  /// Whether there is anything to show beyond the address.
  bool get isEmpty => title == null && description == null && image == null;

  Json toJson() => {
    'url': url.toString(),
    'title': ?title,
    'description': ?description,
    'site': ?site,
    if (image case final image?) 'image': base64Encode(image),
  };

  /// One line of plain text: whitespace collapsed, cut to [max] characters,
  /// or null when empty.
  static String? clean(Object? value, int max) {
    if (value is! String) return null;
    final text = value
        .replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return null;
    final runes = text.runes.toList();
    return runes.length <= max
        ? text
        : '${String.fromCharCodes(runes.take(max - 1)).trimRight()}…';
  }

  /// Whether [bytes] start like a JPEG or PNG.
  static bool imageBytes(Uint8List bytes) =>
      (bytes.length > 3 &&
          bytes[0] == 0xff &&
          bytes[1] == 0xd8 &&
          bytes[2] == 0xff) ||
      (bytes.length > 8 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4e &&
          bytes[3] == 0x47);

  /// A web address a preview may be about: http or https with a host, and
  /// no user name or password in it.
  static Uri? webUrl(Object? value) {
    if (value is! String || value.length > maxUrl) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri;
  }

  /// The preview a payload's `link` field describes, or null when it is
  /// missing or out of bounds. Texts over their limit are refused rather
  /// than cut, as an honest sender never makes them; an unusable image is
  /// left out.
  static LinkPreview? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = webUrl(json['url']);
    if (url == null) return null;
    String? field(String key, int max) {
      final value = json[key];
      if (value is! String) return null;
      if (value.length > max * 2) throw const FormatException();
      return clean(value, max);
    }

    try {
      Uint8List? image;
      if (json['image'] case final String encoded
          when encoded.length <= (maxImageBytes * 4 / 3).ceil() + 4) {
        try {
          final bytes = base64Decode(encoded);
          if (bytes.length <= maxImageBytes && imageBytes(bytes)) {
            image = bytes;
          }
        } on FormatException {
          image = null;
        }
      }
      final preview = LinkPreview(
        url: url,
        title: field('title', maxTitle),
        description: field('description', maxDescription),
        site: field('site', maxSite),
        image: image,
      );
      return preview.isEmpty ? null : preview;
    } on FormatException {
      return null;
    }
  }

  /// The preview in message [payload], if it is about a link still in
  /// [text] (the message's current text, after any edit).
  static LinkPreview? of(Json payload, String text) {
    final preview = fromJson(payload['link']);
    if (preview == null) return null;
    final url = preview.url.toString();
    return text.contains(url) || text.contains(_withoutScheme(url))
        ? preview
        : null;
  }

  static String _withoutScheme(String url) =>
      url.replaceFirst(RegExp(r'^https?://'), '');
}
