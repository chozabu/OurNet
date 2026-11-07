import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:ournet_core/ournet_core.dart';

/// Makes previews of web links on the sending device (see [LinkPreview]),
/// so the people a message goes to never contact the site themselves.
///
/// Fetching tells the site this device's address, so it can be turned off
/// ([enabledSetting]). Only public hosts are fetched, never this machine or
/// its local network, so pasting a router's address does not put its page in
/// a message.
class LinkPreviews {
  static const enabledSetting = 'linkPreviews';
  static const _maxHtmlBytes = 512 * 1024;
  static const _maxImageSourceBytes = 4 * 1024 * 1024;
  static const _maxRedirects = 3;
  static const _timeout = Duration(seconds: 8);
  static const _userAgent = 'Mozilla/5.0 (compatible; OurNet link preview)';

  final Node node;
  LinkPreviews(this.node, {http.Client Function()? client})
    : _client = client ?? http.Client.new;
  final http.Client Function() _client;

  /// Recent results by URL; a null result is remembered too, so a page with
  /// nothing to show is not fetched again on every key press.
  final _cache = <String, Future<LinkPreview?>>{};
  static const _cacheSize = 32;

  bool get enabled => node.store.setting(enabledSetting) != false;

  /// The preview for [url], fetching it at most once while it is cached.
  Future<LinkPreview?> preview(Uri url) {
    final key = url.toString();
    final existing = _cache.remove(key);
    if (existing != null) return _cache[key] = existing;
    if (_cache.length >= _cacheSize) _cache.remove(_cache.keys.first);
    return _cache[key] = _make(url).catchError((Object e) {
      debugPrint('Link preview of ${url.host} failed: $e');
      return null;
    });
  }

  /// The result for [url] if one has finished, without fetching.
  Future<LinkPreview?>? cached(Uri url) => _cache[url.toString()];

  Future<LinkPreview?> _make(Uri url) async {
    if (!enabled) return null;
    final client = _client();
    try {
      final page = await _get(client, url, _maxHtmlBytes, html: true);
      if (page == null) return null;
      final (at, bytes) = page;
      final meta = parseHtml(utf8.decode(bytes, allowMalformed: true), at);
      Uint8List? image;
      if (meta.image case final source?) {
        try {
          final got = await _get(client, source, _maxImageSourceBytes);
          if (got != null) image = await shrink(got.$2);
        } catch (e) {
          debugPrint('Link preview image from ${source.host} failed: $e');
        }
      }
      final preview = LinkPreview(
        url: url,
        title: meta.title,
        description: meta.description,
        site: meta.site,
        image: image,
      );
      return preview.isEmpty ? null : preview;
    } finally {
      client.close();
    }
  }

  /// GETs [url], following a few redirects and checking each host, reading
  /// at most [limit] bytes. Null for an error status or the wrong type.
  Future<(Uri, Uint8List)?> _get(
    http.Client client,
    Uri url,
    int limit, {
    bool html = false,
  }) async {
    var at = url;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      if (LinkPreview.webUrl(at.toString()) == null ||
          !await publicHost(at.host)) {
        return null;
      }
      final request = http.Request('GET', at)
        ..followRedirects = false
        ..headers.addAll({
          'User-Agent': _userAgent,
          'Accept': html
              ? 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.1'
              : 'image/*',
        });
      final response = await client.send(request).timeout(_timeout);
      if (response.isRedirect ||
          const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers['location'];
        await response.stream.drain<void>().catchError((_) {});
        if (location == null) return null;
        at = at.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        await response.stream.drain<void>().catchError((_) {});
        return null;
      }
      final type = response.headers['content-type']?.toLowerCase() ?? '';
      if (html ? !type.contains('html') : !type.startsWith('image/')) {
        await response.stream.drain<void>().catchError((_) {});
        return null;
      }
      final declared = response.contentLength;
      if (!html && declared != null && declared > limit) return null;
      final out = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(_timeout)) {
        out.add(chunk);
        // A page's head is all a preview needs, so a long page is cut;
        // an image cut short would be broken, so it is refused instead.
        if (out.length >= limit) {
          if (!html) return null;
          break;
        }
      }
      return (at, out.takeBytes());
    }
    return null;
  }

  /// Whether every address [host] names is on the public internet.
  @visibleForTesting
  static Future<bool> Function(String host) publicHost = _publicHost;

  static Future<bool> _publicHost(String host) async {
    final name = host.toLowerCase();
    if (name == 'localhost' ||
        name.endsWith('.localhost') ||
        name.endsWith('.local') ||
        name.endsWith('.internal') ||
        name.endsWith('.lan') ||
        name.endsWith('.home.arpa')) {
      return false;
    }
    final literal = InternetAddress.tryParse(name);
    final addresses = literal != null
        ? [literal]
        : await InternetAddress.lookup(name).timeout(_timeout);
    return addresses.isNotEmpty && addresses.every(_public);
  }

  static bool _public(InternetAddress a) {
    if (a.isLoopback || a.isLinkLocal || a.isMulticast) return false;
    final b = a.rawAddress;
    if (a.type == InternetAddressType.IPv4) {
      return !(b[0] == 0 ||
          b[0] == 10 ||
          (b[0] == 100 && b[1] >= 64 && b[1] < 128) ||
          (b[0] == 169 && b[1] == 254) ||
          (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
          (b[0] == 192 && b[1] == 168) ||
          b[0] >= 224);
    }
    // IPv6: unique local (fc00::/7), unspecified, and IPv4-mapped private.
    if ((b[0] & 0xfe) == 0xfc) return false;
    if (b.every((x) => x == 0)) return false;
    final mapped =
        b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
    if (mapped) {
      return _public(
        InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))),
      );
    }
    return true;
  }

  /// Title, description, site name and image of an HTML page at [at], from
  /// its Open Graph and Twitter card tags, falling back to `<title>` and the
  /// description meta tag.
  @visibleForTesting
  static ({String? title, String? description, String? site, Uri? image})
  parseHtml(String source, Uri at) {
    final doc = html.parse(source);
    final meta = <String, String>{};
    for (final dom.Element e in doc.querySelectorAll('meta')) {
      final key = (e.attributes['property'] ?? e.attributes['name'])
          ?.toLowerCase()
          .trim();
      final content = e.attributes['content'];
      if (key != null && content != null) meta.putIfAbsent(key, () => content);
    }
    String? first(List<String> keys, int max) {
      for (final k in keys) {
        if (LinkPreview.clean(meta[k], max) case final v?) return v;
      }
      return null;
    }

    final title =
        first(['og:title', 'twitter:title'], LinkPreview.maxTitle) ??
        LinkPreview.clean(
          doc.querySelector('title')?.text,
          LinkPreview.maxTitle,
        );
    final imageRef = first([
      'og:image:secure_url',
      'og:image',
      'og:image:url',
      'twitter:image',
      'twitter:image:src',
    ], LinkPreview.maxUrl);
    Uri? image;
    if (imageRef != null) {
      final resolved = Uri.tryParse(imageRef);
      image = resolved == null
          ? null
          : LinkPreview.webUrl(at.resolveUri(resolved).toString());
    }
    return (
      title: title,
      description: first([
        'og:description',
        'twitter:description',
        'description',
      ], LinkPreview.maxDescription),
      site: first(['og:site_name'], LinkPreview.maxSite),
      image: image,
    );
  }

  /// [bytes] decoded by the engine at most [LinkPreview.imageEdge] on its
  /// longer side and re-encoded to fit [LinkPreview.maxImageBytes]; null if
  /// it cannot be decoded or will not fit.
  Future<Uint8List?> shrink(Uint8List bytes) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodecWithSize(
        await ui.ImmutableBuffer.fromUint8List(bytes),
        getTargetSize: (width, height) {
          final longest = math.max(width, height);
          if (longest <= LinkPreview.imageEdge) {
            return ui.TargetImageSize(width: width, height: height);
          }
          return ui.TargetImageSize(
            width: math.max(
              1,
              (width * LinkPreview.imageEdge / longest).round(),
            ),
          );
        },
      );
      image = (await codec.getNextFrame()).image;
      // Tiny images are tracking pixels or icons, not previews.
      if (image.width < 32 || image.height < 32) return null;
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (data == null) return null;
      return await node.blobs.encodeAvatar(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        image.width,
        image.height,
        maxBytes: LinkPreview.maxImageBytes,
      );
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }
}
