import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';
import '../services/messaging.dart';
import 'message_text.dart';

/// Searches one conversation when asked. Message text is encrypted at rest
/// with no plaintext index, so this reads the conversation newest first, a
/// page at a time with pauses, and says how far it has got.
class ConversationSearch extends StatefulWidget {
  final Node node;
  final MessageUpdates updates;
  final String peer;
  final String Function(String person) name;
  final void Function(SignedObject message) onOpen;
  final VoidCallback onClose;
  const ConversationSearch({
    super.key,
    required this.node,
    required this.updates,
    required this.peer,
    required this.name,
    required this.onOpen,
    required this.onClose,
  });

  @override
  State<ConversationSearch> createState() => _ConversationSearchState();
}

class _ConversationSearchState extends State<ConversationSearch> {
  final query = TextEditingController();
  final results = <(SignedObject, String)>[];
  static const _limit = 200;
  Timer? _debounce;
  int _generation = 0;
  int checked = 0;
  bool searching = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _generation++;
    query.dispose();
    super.dispose();
  }

  void _changed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _search);
  }

  Future<void> _search() async {
    final generation = ++_generation;
    final needle = query.text.trim().toLowerCase();
    setState(() {
      results.clear();
      checked = 0;
      searching = needle.isNotEmpty;
    });
    if (needle.isEmpty) return;
    final node = widget.node;
    final slice = TimeSlice();
    SignedObject? before;
    while (generation == _generation && results.length < _limit) {
      final page = node.store.conversation(
        node.person,
        widget.peer,
        before: before,
        limit: 100,
      );
      if (page.isEmpty) break;
      for (final o in page) {
        await slice.pause();
        if (generation != _generation) return;
        if (widget.updates.hidden(o)) continue;
        final payload = await node.content(o);
        if (payload == null) continue;
        final current = widget.updates.current(o, payload);
        final text = MessageText.plain(contentPreview(current));
        if (text.toLowerCase().contains(needle)) results.add((o, text));
      }
      checked += page.length;
      before = page.last;
      if (mounted) setState(() {});
    }
    if (generation == _generation && mounted) {
      setState(() => searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needle = query.text.trim();
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Close search',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.arrow_back),
                ),
                Expanded(
                  child: TextField(
                    controller: query,
                    autofocus: true,
                    onChanged: _changed,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: 'Search with ${widget.name(widget.peer)}',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                  ),
                ),
                if (searching)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
          if (needle.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: results.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        searching
                            ? 'Searching… $checked messages checked'
                            : 'No messages match',
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final (o, text) in results)
                          ListTile(
                            dense: true,
                            title: Text(
                              text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${widget.name(o.author)} · '
                              '${DateTime.fromMillisecondsSinceEpoch(o.created).toLocal().toString().substring(0, 16)}',
                            ),
                            onTap: () => widget.onOpen(o),
                          ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            searching
                                ? 'Searching… $checked messages checked'
                                : results.length >= _limit
                                ? 'Showing the newest $_limit matches'
                                : '${results.length} '
                                      '${results.length == 1 ? 'match' : 'matches'}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}
