import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

class _WikiLink extends md.InlineSyntax {
  _WikiLink() : super(r'\[\[([^\]]+)\]\]');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element.text('a', match[1]!)
        ..attributes['href'] = 'ournet-wiki:${Uri.encodeComponent(match[1]!)}',
    );
    return true;
  }
}

/// Parsing and HTML normalization run off the UI isolate, once per document.
/// Only presentation HTML is retained: no scripts, forms, local files or CSS
/// resource URLs can bypass the image/link handlers below.
String markdownHtml(String source) {
  final fragment = html.parseFragment(
    md.markdownToHtml(
      source,
      extensionSet: md.ExtensionSet.gitHubWeb,
      inlineSyntaxes: [_WikiLink()],
    ),
  );
  const allowed = {
    'a',
    'abbr',
    'b',
    'blockquote',
    'br',
    'caption',
    'code',
    'dd',
    'del',
    'details',
    'div',
    'dl',
    'dt',
    'em',
    'figcaption',
    'figure',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'hr',
    'i',
    'img',
    'input',
    'ins',
    'kbd',
    'li',
    'mark',
    'ol',
    'p',
    'pre',
    's',
    'small',
    'span',
    'strike',
    'strong',
    'sub',
    'summary',
    'sup',
    'table',
    'tbody',
    'td',
    'th',
    'thead',
    'tfoot',
    'tr',
    'u',
    'ul',
  };
  const attributes = {
    'href',
    'src',
    'alt',
    'title',
    'id',
    'name',
    'width',
    'height',
    'align',
    'colspan',
    'rowspan',
    'start',
    'reversed',
    'type',
    'checked',
    'open',
    'class',
  };
  // Reverse order allows unwrapping unknown tags without losing their children.
  for (final e in fragment.querySelectorAll('*').reversed) {
    if (const {
      'script',
      'style',
      'iframe',
      'object',
      'embed',
      'form',
    }.contains(e.localName)) {
      e.remove();
      continue;
    }
    if (!allowed.contains(e.localName)) {
      e.replaceWith(dom.DocumentFragment()..nodes.addAll(e.nodes.toList()));
      continue;
    }
    final alignment = RegExp(
      r'^text-align:\s*(left|right|center);?$',
    ).firstMatch(e.attributes['style'] ?? '')?.group(1);
    e.attributes.removeWhere((k, v) => !attributes.contains(k));
    if (alignment != null) e.attributes['align'] = alignment;
    if (e.localName == 'input' && e.attributes['type'] != 'checkbox') {
      e.remove();
    }
  }
  return fragment.outerHtml;
}

/// Resolve a repository URL relative to the document, with root-relative and
/// parent paths, escaped names, query strings and fragments handled as URLs.
String? markdownRepositoryPath(String directory, String target) {
  final uri = Uri.tryParse(target);
  if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
  // Segments are resolved after decoding, so `%2e%2e` counts as `..`; going
  // above the repository root is refused rather than clamped.
  final path = uri.path.startsWith('/')
      ? <String>[]
      : directory.split('/').where((p) => p.isNotEmpty).toList();
  for (final p in uri.pathSegments) {
    if (p.isEmpty || p == '.') continue;
    if (p == '..') {
      if (path.isEmpty) return null;
      path.removeLast();
    } else if (p.contains('/') || p.contains('\\') || p.contains('\x00')) {
      return null;
    } else {
      path.add(p);
    }
  }
  return path.join('/');
}

typedef MarkdownRepositoryFile =
    Future<Uint8List> Function(String repository, String commit, String path);

/// GFM plus presentation HTML, shared by plugin READMEs, wiki and posts.
class PluginMarkdown extends StatefulWidget {
  final String text;
  final ValueChanged<String>? onLink;
  final Widget Function(String id, double? height)? attachmentImage;
  final MarkdownRepositoryFile? repositoryFile;
  final String repository, commit, directory;
  const PluginMarkdown({
    super.key,
    required this.text,
    this.onLink,
    this.attachmentImage,
    this.repositoryFile,
    this.repository = '',
    this.commit = '',
    this.directory = '',
  });

  @override
  State<PluginMarkdown> createState() => _PluginMarkdownState();
}

class _PluginMarkdownState extends State<PluginMarkdown> {
  late Future<String> _html;
  final _resources = _ImageResources();
  @override
  void initState() {
    super.initState();
    _parse();
  }

  void _parse() {
    _html = compute(markdownHtml, widget.text);
  }

  @override
  void didUpdateWidget(PluginMarkdown old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _parse();
  }

  @override
  void dispose() {
    _resources.close();
    super.dispose();
  }

  Future<bool> _link(String target) async {
    if (target.startsWith('#')) return false; // renderer scrolls to heading IDs
    final uri = Uri.tryParse(target);
    if (uri == null) return true;
    if (uri.scheme == 'ournet-wiki') {
      widget.onLink?.call(
        Uri.decodeComponent(target.substring('ournet-wiki:'.length)),
      );
    } else if (const {'https', 'http', 'mailto'}.contains(uri.scheme)) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        _message('Could not open this link');
      }
    } else if (!uri.hasScheme && !uri.hasAuthority) {
      final path = widget.repository.isEmpty
          ? target
          : markdownRepositoryPath(widget.directory, target);
      if (path != null) widget.onLink?.call(path);
    }
    return true;
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Widget? _element(dom.Element e) {
    if (e.localName == 'pre') {
      return _CodeBlock(
        e.text,
        language: e
            .querySelector('code')
            ?.classes
            .where((c) => c.startsWith('language-'))
            .firstOrNull
            ?.substring(9),
      );
    }
    if (e.localName == 'input') {
      return InlineCustomWidget(
        child: Icon(
          e.attributes.containsKey('checked')
              ? Icons.check_box
              : Icons.check_box_outline_blank,
          size: 18,
          semanticLabel: e.attributes.containsKey('checked')
              ? 'Checked'
              : 'Unchecked',
        ),
      );
    }
    if (e.localName != 'img') return null;
    final src = e.attributes['src'] ?? '';
    final alt = e.attributes['alt'] ?? 'Image';
    final uri = Uri.tryParse(src);
    final height = double.tryParse(e.attributes['height'] ?? '');
    if (widget.repository.isEmpty &&
        !src.contains('.') &&
        RegExp(r'^[A-Za-z0-9_=+/-]{8,128}$').hasMatch(src)) {
      return widget.attachmentImage?.call(src, height ?? 320) ?? Text(alt);
    }
    final path = markdownRepositoryPath(widget.directory, src);
    final remote = uri != null && const {'http', 'https'}.contains(uri.scheme);
    if (!remote &&
        (widget.repository.isEmpty ||
            path == null ||
            widget.repositoryFile == null)) {
      return Text('$alt — image unavailable');
    }
    final key = remote ? src : '${widget.repository}/${widget.commit}/$path';
    final image = _MarkdownImage(
      key: ValueKey(key),
      alt: alt,
      height: height,
      load: () => _resources.read(
        key,
        () => remote
            ? _networkImage(uri)
            : widget.repositoryFile!(widget.repository, widget.commit, path!),
      ),
    );
    // Tables size columns by their content's intrinsic width, which for a
    // picture is its pixel size. Report the cell's `width` share instead, so
    // README image grids split evenly whatever the screenshots' sizes.
    final cell = e.parent;
    if (cell == null || !const {'td', 'th'}.contains(cell.localName)) {
      return image;
    }
    final share = RegExp(
      r'^(\d+(?:\.\d+)?)%$',
    ).firstMatch(cell.attributes['width'] ?? '')?.group(1);
    return _CellWidth(
      width: (double.tryParse(share ?? '') ?? 50) * 10,
      child: image,
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _html,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return const Text('Could not render this document');
      }
      if (!snapshot.hasData) {
        return const Padding(
          padding: EdgeInsets.all(12),
          child: LinearProgressIndicator(),
        );
      }
      final colors = Theme.of(context).colorScheme;
      return SelectionArea(
        child: HtmlWidget(
          snapshot.data!,
          buildAsync: true,
          enableCaching: true,
          rebuildTriggers: [widget.repository, widget.commit, widget.directory],
          textStyle: Theme.of(context).textTheme.bodyMedium,
          customWidgetBuilder: _element,
          onTapUrl: _link,
          customStylesBuilder: (e) => switch (e.localName) {
            'code' || 'kbd' => {'font-family': 'monospace'},
            'table' => {'border-collapse': 'collapse'},
            'th' || 'td' => {
              'padding': '8px',
              'border':
                  '1px solid #${colors.outlineVariant.toARGB32().toRadixString(16).substring(2)}',
            },
            'blockquote' => {
              'padding-left': '12px',
              'border-left':
                  '3px solid #${colors.outlineVariant.toARGB32().toRadixString(16).substring(2)}',
            },
            _ => null,
          },
        ),
      );
    },
  );
}

class _CellWidth extends SingleChildRenderObjectWidget {
  final double width;
  const _CellWidth({required this.width, super.child});
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCellWidth(width);
  @override
  void updateRenderObject(BuildContext context, _RenderCellWidth render) =>
      render.width = width;
}

class _RenderCellWidth extends RenderProxyBox {
  _RenderCellWidth(this._width);
  double _width;
  bool _relayout = false;
  set width(double value) {
    if (value == _width) return;
    _width = value;
    markNeedsLayout();
  }

  // A loose width is the table measuring the column: claim the share whether
  // or not the picture has loaded, so a late image never finds its column
  // already sized to nothing.
  BoxConstraints _limit(BoxConstraints c) => c.hasTightWidth
      ? c
      : c.tighten(
          width: c.maxWidth.isFinite
              ? math.max(c.minWidth, math.min(c.maxWidth, _width))
              : _width,
        );

  @override
  double computeMinIntrinsicWidth(double height) => 48;
  @override
  double computeMaxIntrinsicWidth(double height) => _width;
  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(
    child?.getDryLayout(_limit(constraints)) ?? Size.zero,
  );
  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_limit(constraints), parentUsesSize: true);
    size = constraints.constrain(child.size);
    // The table finally lays cells out at a tight size, which stops a picture
    // that loads later from resizing its row. When it needs more height than
    // the row gave, relayout up to the table (the first ancestor free to
    // grow) after this frame; rows only grow, so this settles.
    if (!constraints.hasBoundedHeight || _relayout) return;
    final wanted = child.getDryLayout(
      constraints.copyWith(minHeight: 0, maxHeight: double.infinity),
    );
    if (wanted.height <= constraints.maxHeight + 0.5) return;
    _relayout = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _relayout = false;
      if (!attached) return;
      for (RenderObject? p = parent; p != null; p = p.parent) {
        p.markNeedsLayout();
        final c = p.constraints;
        if (c is! BoxConstraints || !c.hasBoundedHeight) break;
      }
    });
  }
}

class _CodeBlock extends StatelessWidget {
  final String text;
  final String? language;
  const _CodeBlock(this.text, {this.language});
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                language ?? 'Code',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            IconButton(
              tooltip: 'Copy code',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            ),
          ],
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(
            text.replaceFirst(RegExp(r'\n$'), ''),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
      ],
    ),
  );
}

const _imageBytes =
    16 * 1024 * 1024; // preview budget, never a repository limit
Future<Uint8List> _networkImage(Uri uri) async {
  final client = http.Client();
  try {
    final response = await client
        .send(http.Request('GET', uri))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('Image HTTP ${response.statusCode}');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      if (bytes.length + chunk.length > _imageBytes) {
        throw StateError('Image exceeds preview budget');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  } finally {
    client.close();
  }
}

/// Shared per document: two reads at once, bounded waiting/cache memory.
class _ImageResources {
  final _cache = <String, Uint8List>{};
  final _pending = <String, Future<Uint8List>>{};
  final _waiting = Queue<Completer<void>>();
  int _active = 0, _bytes = 0;
  bool _closed = false;
  Future<Uint8List> read(String key, Future<Uint8List> Function() load) {
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return Future.value(cached);
    }
    // The callback must not return the removed future: whenComplete would
    // then wait for itself.
    return _pending[key] ??= _run(key, load).whenComplete(() {
      _pending.remove(key);
    });
  }

  Future<Uint8List> _run(String key, Future<Uint8List> Function() load) async {
    if (_closed || _waiting.length >= 16) {
      throw StateError('Image queue full; retry');
    }
    if (_active >= 2) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      _active++;
    }
    if (_closed) throw StateError('Document closed');
    try {
      final data = await load();
      if (data.length > _imageBytes) {
        throw StateError('Image exceeds preview budget');
      }
      if (!_closed && data.length <= 8 * 1024 * 1024) {
        _cache[key] = data;
        _bytes += data.length;
        while (_bytes > 8 * 1024 * 1024 || _cache.length > 16) {
          _bytes -= _cache.remove(_cache.keys.first)!.length;
        }
      }
      return data;
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }

  void close() {
    _closed = true;
    _cache.clear();
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    }
  }
}

class _MarkdownImage extends StatefulWidget {
  final String alt;
  final double? height;
  final Future<Uint8List> Function() load;
  const _MarkdownImage({
    super.key,
    required this.alt,
    this.height,
    required this.load,
  });
  @override
  State<_MarkdownImage> createState() => _MarkdownImageState();
}

class _MarkdownImageState extends State<_MarkdownImage> {
  late Future<Uint8List> _data;
  @override
  void initState() {
    super.initState();
    _data = widget.load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _data,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return TextButton.icon(
          onPressed: () => setState(() {
            _data = widget.load();
          }),
          icon: const Icon(Icons.refresh),
          label: Text('${widget.alt} — retry image'),
        );
      }
      if (!snapshot.hasData) {
        return SizedBox(
          height: widget.height ?? 120,
          child: const Center(child: CircularProgressIndicator()),
        );
      }
      final bytes = snapshot.data!;
      final isSvg = utf8
          .decode(bytes.take(512).toList(), allowMalformed: true)
          .contains('<svg');
      final child = isSvg
          ? SvgPicture.memory(
              bytes,
              semanticsLabel: widget.alt,
              height: widget.height,
              fit: BoxFit.contain,
            )
          : Image.memory(
              bytes,
              semanticLabel: widget.alt,
              height: widget.height,
              fit: BoxFit.contain,
              cacheWidth: 1200,
              errorBuilder: (_, _, _) =>
                  Text('${widget.alt} — unsupported image'),
            );
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 640),
        child: child,
      );
    },
  );
}
