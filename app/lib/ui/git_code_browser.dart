import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:highlight/highlight.dart' as syntax;
import 'package:rfw/rfw.dart';

typedef CodeLine = List<(String, String)>;

class CodeDocument {
  final List<CodeLine> lines;
  final int columns;
  CodeDocument(this.lines, this.columns);
}

CodeDocument parseGitCode((String, String) input) {
  final (name, text) = input;
  final extension = name.split('.').last.toLowerCase();
  const languages = {
    'rs': 'rust',
    'dart': 'dart',
    'py': 'python',
    'js': 'javascript',
    'jsx': 'javascript',
    'ts': 'typescript',
    'tsx': 'typescript',
    'c': 'cpp',
    'h': 'cpp',
    'cpp': 'cpp',
    'hpp': 'cpp',
    'cs': 'cs',
    'java': 'java',
    'go': 'go',
    'json': 'json',
    'yaml': 'yaml',
    'yml': 'yaml',
    'html': 'xml',
    'xml': 'xml',
    'css': 'css',
    'sh': 'bash',
    'ps1': 'powershell',
    'toml': 'ini',
    'md': 'markdown',
  };
  final lines = <CodeLine>[[]];
  void add(String value, String scope) {
    final pieces = value.split('\n');
    for (var i = 0; i < pieces.length; i++) {
      if (i > 0) lines.add([]);
      if (pieces[i].isNotEmpty) lines.last.add((pieces[i], scope));
    }
  }

  void visit(List<syntax.Node> nodes, String parent) {
    for (final node in nodes) {
      final scope = node.className ?? parent;
      if (node.value != null) add(node.value!, scope);
      if (node.children != null) visit(node.children!, scope);
    }
  }

  try {
    final language = languages[extension];
    if (language == null) {
      add(text, '');
    } else {
      visit(syntax.highlight.parse(text, language: language).nodes ?? [], '');
    }
  } catch (_) {
    lines.clear();
    lines.add([]);
    add(text, '');
  }
  var columns = 0;
  for (final line in lines) {
    columns = math.max(
      columns,
      line.fold<int>(0, (n, s) => n + s.$1.replaceAll('\t', '    ').length),
    );
  }
  return CodeDocument(lines, columns);
}

List<int> findGitCode((String, String) input) {
  final needle = input.$2.toLowerCase();
  if (needle.isEmpty) return [];
  final lines = input.$1.toLowerCase().split('\n');
  return [
    for (var i = 0; i < lines.length; i++)
      if (lines[i].contains(needle)) i,
  ];
}

Widget gitCodeWidget(BuildContext context, DataSource source) {
  final repo = source.v<String>(['repository']) ?? '';
  final commit = source.v<String>(['commit']) ?? '';
  final path = source.v<String>(['path']) ?? '';
  return GitCodeBrowser(
    key: PageStorageKey('$repo/$commit/$path'),
    repository: repo,
    commit: commit,
    path: path,
    initialLine: source.v<int>(['line']) ?? 0,
    text: source.v<String>(['text']) ?? '',
    entries: [
      for (var i = 0; i < source.length(['entries']); i++)
        (
          source.v<String>(['entries', i, 'name']) ?? '',
          source.v<bool>(['entries', i, 'dir']) ?? false,
        ),
    ],
    onOpen: source.handler<void Function(String, bool)>(
      ['onOpen'],
      (trigger) =>
          (name, dir) => trigger({'name': name, 'dir': dir}),
    ),
  );
}

class GitCodeBrowser extends StatefulWidget {
  final String repository, commit, path, text;
  final List<(String, bool)> entries;
  final int initialLine;
  final void Function(String, bool)? onOpen;
  const GitCodeBrowser({
    super.key,
    required this.repository,
    required this.commit,
    required this.path,
    required this.text,
    this.entries = const [],
    this.initialLine = 0,
    this.onOpen,
  });
  @override
  State<GitCodeBrowser> createState() => _GitCodeBrowserState();
}

class _GitCodeBrowserState extends State<GitCodeBrowser> {
  late Future<CodeDocument> _document;
  final _scroll = ScrollController();
  Timer? _debounce;
  final _query = TextEditingController();
  List<int> _matches = [];
  int _selected = 1, _end = 1, _match = 0, _generation = 0;
  bool _folders = false;
  bool _jumpPending = true;
  @override
  void initState() {
    super.initState();
    _document = compute(parseGitCode, (widget.path, widget.text));
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  void _search(String query) {
    _debounce?.cancel();
    final generation = ++_generation;
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      final matches = await compute(findGitCode, (widget.text, query));
      if (!mounted || generation != _generation) return;
      setState(() {
        _matches = matches;
        _match = 0;
      });
      if (matches.isNotEmpty) _jump(matches.first);
    });
  }

  void _jump(int line) {
    if (_scroll.hasClients) {
      _scroll.jumpTo(math.min(_scroll.position.maxScrollExtent, line * 24.0));
    }
    setState(() {
      _selected = line + 1;
      _end = _selected;
    });
  }

  String get _link => Uri.parse(widget.repository)
      .replace(
        queryParameters: {'commit': widget.commit, 'path': widget.path},
        fragment: _selected == _end
            ? 'L$_selected'
            : 'L${math.min(_selected, _end)}-L${math.max(_selected, _end)}',
      )
      .toString();
  Color? _color(String scope, ColorScheme colors) =>
      switch (scope.split('.').first) {
        'keyword' || 'selector-tag' || 'built_in' => colors.primary,
        'string' || 'regexp' || 'attr' => Colors.green.shade700,
        'number' || 'literal' => Colors.deepOrange,
        'comment' || 'quote' => colors.outline,
        'title' || 'function' || 'type' => colors.tertiary,
        _ => null,
      };
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, layout) {
      final colors = Theme.of(context).colorScheme;
      final sidebar = layout.maxWidth > 850 || _folders;
      return Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Browse folder',
                onPressed: () => setState(() => _folders = !_folders),
                icon: const Icon(Icons.account_tree_outlined),
              ),
              Expanded(
                child: TextField(
                  controller: _query,
                  onChanged: _search,
                  decoration: const InputDecoration(
                    hintText: 'Find in file',
                    isDense: true,
                  ),
                ),
              ),
              Text(_matches.isEmpty ? '' : '${_match + 1}/${_matches.length}'),
              IconButton(
                tooltip: 'Next match',
                onPressed: _matches.isEmpty
                    ? null
                    : () {
                        _match = (_match + 1) % _matches.length;
                        _jump(_matches[_match]);
                      },
                icon: const Icon(Icons.arrow_downward, size: 18),
              ),
              IconButton(
                tooltip: 'Copy line link',
                onPressed: () => Clipboard.setData(ClipboardData(text: _link)),
                icon: const Icon(Icons.link),
              ),
              IconButton(
                tooltip: 'Copy file',
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: widget.text)),
                icon: const Icon(Icons.copy),
              ),
            ],
          ),
          Expanded(
            child: Row(
              children: [
                if (sidebar)
                  SizedBox(
                    width: math.min(220, layout.maxWidth * 0.4),
                    child: ListView.builder(
                      itemCount: widget.entries.length,
                      itemBuilder: (context, index) {
                        final (name, dir) = widget.entries[index];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            dir
                                ? Icons.folder_outlined
                                : Icons.description_outlined,
                            size: 18,
                          ),
                          selected: widget.path.split('/').last == name,
                          title: Text(name, overflow: TextOverflow.ellipsis),
                          onTap: () => widget.onOpen?.call(name, dir),
                        );
                      },
                    ),
                  ),
                Expanded(
                  child: FutureBuilder<CodeDocument>(
                    future: _document,
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final doc = snapshot.data!;
                      if (_jumpPending && widget.initialLine > 0) {
                        _jumpPending = false;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) {
                            _jump(
                              math.min(
                                doc.lines.length - 1,
                                widget.initialLine - 1,
                              ),
                            );
                          }
                        });
                      }
                      return SelectionArea(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: math.max(500, doc.columns * 8.0 + 95),
                            child: ListView.builder(
                              controller: _scroll,
                              itemExtent: 24,
                              itemCount: doc.lines.length,
                              itemBuilder: (context, i) {
                                final selected =
                                    i + 1 >= math.min(_selected, _end) &&
                                    i + 1 <= math.max(_selected, _end);
                                return ColoredBox(
                                  color: selected
                                      ? colors.primaryContainer
                                      : colors.surface,
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 65,
                                        child: InkWell(
                                          onTap: () => setState(() {
                                            if (HardwareKeyboard
                                                .instance
                                                .isShiftPressed) {
                                              _end = i + 1;
                                            } else {
                                              _selected = i + 1;
                                              _end = i + 1;
                                            }
                                          }),
                                          child: Text(
                                            '${i + 1}  ',
                                            textAlign: TextAlign.right,
                                            style: TextStyle(
                                              fontFamily: 'monospace',
                                              color: colors.outline,
                                            ),
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: Text.rich(
                                          TextSpan(
                                            children: [
                                              for (final (text, scope)
                                                  in doc.lines[i])
                                                TextSpan(
                                                  text: text.replaceAll(
                                                    '\t',
                                                    '    ',
                                                  ),
                                                  style: TextStyle(
                                                    color: _color(
                                                      scope,
                                                      colors,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                          softWrap: false,
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 13,
                                            height: 1.5,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

Widget gitLocationWidget(BuildContext context, DataSource source) =>
    _GitLocationInput(
      onOpen: source.handler<void Function(Map<String, Object>)>(
        ['onOpen'],
        (trigger) =>
            (args) => trigger(args),
      ),
    );

class _GitLocationInput extends StatefulWidget {
  final ValueChanged<Map<String, Object>>? onOpen;
  const _GitLocationInput({this.onOpen});
  @override
  State<_GitLocationInput> createState() => _GitLocationInputState();
}

class _GitLocationInputState extends State<_GitLocationInput> {
  String? error;
  @override
  Widget build(BuildContext context) => TextField(
    decoration: InputDecoration(
      labelText: 'Open a copied Git location',
      hintText: 'ournet://…?commit=…&path=…#L…',
      errorText: error,
    ),
    onSubmitted: (value) {
      final uri = Uri.tryParse(value);
      final commit = uri?.queryParameters['commit'] ?? '';
      final path = uri?.queryParameters['path'] ?? '';
      if (uri == null ||
          uri.scheme != 'ournet' ||
          uri.host.isEmpty ||
          !RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(commit) ||
          path.isEmpty) {
        setState(
          () => error = 'Paste a repository file link with a commit and path',
        );
        return;
      }
      setState(() => error = null);
      widget.onOpen?.call({
        'repo': uri.host,
        'commit': commit,
        'path': path,
        'line':
            int.tryParse(uri.fragment.replaceFirst('L', '').split('-').first) ??
            1,
      });
    },
  );
}
