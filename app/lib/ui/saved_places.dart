import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

/// A list selected for display; null means no saved markers on the map.
typedef PlaceList = ({String space, String id, String name});

class SavedPlacesPage extends StatefulWidget {
  final Places places;
  final String? scope;
  final void Function(SavedMapEntry) onSelect;
  final void Function(PlaceList?) onShow;
  final PlaceList? shown;
  const SavedPlacesPage({
    super.key,
    required this.places,
    required this.onSelect,
    required this.onShow,
    this.scope,
    this.shown,
  });
  @override
  State<SavedPlacesPage> createState() => _SavedPlacesPageState();
}

class _SavedPlacesPageState extends State<SavedPlacesPage> {
  StreamSubscription<Set<String>>? _sub;
  PlaceList? _list;
  String _query = '';
  String? _error;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _list = widget.shown;
    _sub = widget.places.node.onChangesTo(Places.kinds, _refresh);
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      await widget.places.refresh();
      if (mounted) {
        setState(() {
          _loading = false;
          _error = null;
          final selected = _list;
          if (selected != null &&
              selected.id != Places.saved &&
              !widget.places.lists.any(
                (e) => e.space == selected.space && e.id == selected.id,
              )) {
            _list = null;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final places = widget.places;
    final lists = [
      if (widget.scope == null || widget.scope == Places.personal)
        (space: Places.personal, id: Places.saved, name: 'Saved places'),
      for (final list in places.lists)
        if (widget.scope == null || widget.scope == list.space)
          (space: list.space, id: list.id, name: list.name),
    ];
    final list = _list;
    final entries =
        (list == null ? places.all : places.inList(list.space, list.id))
            .where(
              (e) =>
                  (widget.scope == null || e.space == widget.scope) &&
                  '${e.name} ${e.note} ${e.emoji}'.toLowerCase().contains(
                    _query.toLowerCase(),
                  ),
            )
            .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(list?.name ?? 'Saved places'),
        actions: [
          IconButton(
            tooltip: 'New list',
            icon: const Icon(Icons.playlist_add),
            onPressed: () async {
              final result = await createPlaceList(
                context,
                places,
                scope: widget.scope,
              );
              if (result != null && mounted) setState(() => _list = result);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            ListTile(
              title: Text(_error!),
              trailing: TextButton(
                onPressed: _refresh,
                child: const Text('Retry'),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Find a saved place',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          SizedBox(
            height: 58,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: const Text('All saved'),
                    selected: list == null,
                    onSelected: (_) => setState(() => _list = null),
                  ),
                ),
                for (final item in lists)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        '${item.name} · ${places.scopeName(item.space)}',
                      ),
                      selected:
                          list?.space == item.space && list?.id == item.id,
                      onSelected: (_) => setState(() => _list = item),
                    ),
                  ),
              ],
            ),
          ),
          if (list != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${places.scopeName(list.space)} · ${entries.length} places',
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.map_outlined),
                    label: const Text('Show on map'),
                    onPressed: () {
                      widget.onShow(list);
                      Navigator.pop(context);
                    },
                  ),
                  if (places.lists
                          .where(
                            (e) =>
                                e.space == list.space &&
                                e.id == list.id &&
                                places.canEdit(e),
                          )
                          .firstOrNull
                      case final entry?)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Rename list',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () async {
                            final name = await _rename(context, entry.name);
                            if (name == null) return;
                            try {
                              final edited = await places.edit(
                                entry,
                                name: name,
                                emoji: entry.emoji,
                                note: entry.note,
                              );
                              if (mounted) {
                                setState(
                                  () => _list = (
                                    space: edited.space,
                                    id: edited.id,
                                    name: edited.name,
                                  ),
                                );
                              }
                            } catch (e) {
                              if (mounted) setState(() => _error = '$e');
                            }
                          },
                        ),
                        IconButton(
                          tooltip: 'Delete list',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            if (!await _confirm(
                              context,
                              'Delete ${list.name}?',
                              'The places stay saved. This only removes the list.',
                            )) {
                              return;
                            }
                            try {
                              await places.remove(entry);
                              if (mounted) setState(() => _list = null);
                              if (widget.shown?.id == list.id &&
                                  widget.shown?.space == list.space) {
                                widget.onShow(null);
                              }
                            } catch (e) {
                              if (mounted) setState(() => _error = '$e');
                            }
                          },
                        ),
                      ],
                    ),
                ],
              ),
            ),
          Expanded(
            child: entries.isEmpty && !_loading
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No saved places here yet. Long-press the map, then tap Save.',
                      ),
                    ),
                  )
                : ListView.builder(
                    key: PageStorageKey(
                      list == null ? 'all' : '${list.space}|${list.id}',
                    ),
                    itemCount: entries.length,
                    itemBuilder: (_, i) {
                      final entry = entries[i];
                      return ListTile(
                        leading: Text(
                          entry.emoji,
                          style: const TextStyle(fontSize: 28),
                        ),
                        title: Text(entry.name),
                        subtitle: Text(
                          [
                            places.scopeName(entry.space),
                            if (entry.note.isNotEmpty) entry.note,
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          widget.onSelect(entry);
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

Future<bool> _confirm(BuildContext context, String title, String text) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;

Future<String?> _rename(BuildContext context, String name) async {
  var draft = name;
  return await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rename list'),
      content: TextFormField(
        initialValue: name,
        onChanged: (v) => draft = v,
        autofocus: true,
        maxLength: 100,
        decoration: const InputDecoration(labelText: 'List name'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (draft.trim().isNotEmpty) {
              Navigator.pop(context, draft.trim());
            }
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

Future<PlaceList?> createPlaceList(
  BuildContext context,
  Places places, {
  String? scope,
}) => showDialog<PlaceList>(
  context: context,
  builder: (_) => _NewList(places: places, scope: scope),
);

class _NewList extends StatefulWidget {
  final Places places;
  final String? scope;
  const _NewList({required this.places, this.scope});
  @override
  State<_NewList> createState() => _NewListState();
}

class _NewListState extends State<_NewList> {
  final _name = TextEditingController();
  late String _space = widget.scope ?? Places.personal;
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New list'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 100,
            decoration: const InputDecoration(labelText: 'List name'),
          ),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _space,
            decoration: const InputDecoration(
              labelText: 'Who can see this list?',
            ),
            items: [
              const DropdownMenuItem(
                value: Places.personal,
                child: Text('Private · only you'),
              ),
              for (final g in widget.places.groups)
                DropdownMenuItem(
                  value: g.object.space,
                  child: Text('Group · ${g.data['name']}'),
                ),
            ],
            onChanged: _saving || widget.scope != null
                ? null
                : (v) => setState(() => _space = v!),
          ),
          if (_space != Places.personal)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Members can add places. The list creator and group owner can manage this list.',
              ),
            ),
          if (_error != null) Text(_error!),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _saving
            ? null
            : () async {
                if (_name.text.trim().isEmpty) {
                  setState(() => _error = 'Give the list a name.');
                  return;
                }
                setState(() {
                  _saving = true;
                  _error = null;
                });
                try {
                  final entry = await widget.places.createList(
                    _name.text,
                    space: _space,
                  );
                  if (context.mounted) {
                    Navigator.pop(context, (
                      space: entry.space,
                      id: entry.id,
                      name: entry.name,
                    ));
                  }
                } catch (e) {
                  if (mounted) {
                    setState(() {
                      _saving = false;
                      _error = '$e';
                    });
                  }
                }
              },
        child: Text(_saving ? 'Creating…' : 'Create'),
      ),
    ],
  );
}

Future<SavedMapEntry?> editSavedPlace(
  BuildContext context,
  Places places, {
  required double lat,
  required double lng,
  SavedMapEntry? entry,
  SavedMapEntry? seed,
  PlaceLink? suggestion,
  String? scope,
}) => showDialog<SavedMapEntry>(
  context: context,
  builder: (_) => _PlaceEditor(
    places: places,
    lat: lat,
    lng: lng,
    entry: entry,
    seed: seed,
    suggestion: suggestion,
    scope: scope,
  ),
);

class _PlaceEditor extends StatefulWidget {
  final Places places;
  final double lat, lng;
  final SavedMapEntry? entry;
  final SavedMapEntry? seed;
  final PlaceLink? suggestion;
  final String? scope;
  const _PlaceEditor({
    required this.places,
    required this.lat,
    required this.lng,
    this.entry,
    this.seed,
    this.suggestion,
    this.scope,
  });
  @override
  State<_PlaceEditor> createState() => _PlaceEditorState();
}

class _PlaceEditorState extends State<_PlaceEditor> {
  late final _name = TextEditingController(
    text:
        widget.entry?.name ??
        widget.seed?.name ??
        widget.suggestion?.name ??
        'Dropped pin',
  );
  late final _emoji = TextEditingController(
    text:
        widget.entry?.emoji ??
        widget.seed?.emoji ??
        widget.suggestion?.emoji ??
        '⭐',
  );
  late final _note = TextEditingController(text: widget.entry?.note ?? '');
  late final _private = TextEditingController(
    text: widget.entry == null ? '' : widget.places.privateNote(widget.entry!),
  );
  late String _space = widget.entry?.space ?? Places.personal;
  late Set<String> _lists = widget.entry == null
      ? {Places.saved}
      : widget.places.listsOf(widget.entry!).toSet();
  bool _saving = false;
  late final String _draftId = '${widget.places.node.person}:${randomId()}';
  String? _error;
  bool get _editable =>
      widget.entry == null || widget.places.canEdit(widget.entry!);
  @override
  void dispose() {
    for (final c in [_name, _emoji, _note, _private]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final places = widget.places;
    return AlertDialog(
      title: Text(widget.entry == null ? 'Save place' : 'Place details'),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 82,
                    child: TextField(
                      controller: _emoji,
                      readOnly: !_editable,
                      maxLength: 1,
                      decoration: const InputDecoration(
                        labelText: 'Emoji',
                        counterText: '',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _name,
                      readOnly: !_editable,
                      maxLength: 200,
                      decoration: const InputDecoration(
                        labelText: 'Place name',
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                '${widget.lat.toStringAsFixed(5)}, ${widget.lng.toStringAsFixed(5)}',
              ),
              const SizedBox(height: 12),
              if (widget.entry == null)
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _space,
                  decoration: const InputDecoration(
                    labelText: 'Who can see this place?',
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: Places.personal,
                      child: Text('Private · only you'),
                    ),
                    for (final g in places.groups)
                      DropdownMenuItem(
                        value: g.object.space,
                        child: Text('Group · ${g.data['name']}'),
                      ),
                  ],
                  onChanged: _saving
                      ? null
                      : (v) => setState(() {
                          _space = v!;
                          _lists = _space == Places.personal
                              ? {Places.saved}
                              : {};
                        }),
                )
              else
                Text(
                  places.scopeName(_space),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              TextField(
                controller: _note,
                readOnly: !_editable,
                maxLength: 4000,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: _space == Places.personal
                      ? 'Note'
                      : 'Note shared with this group',
                ),
              ),
              if (_space != Places.personal)
                TextField(
                  controller: _private,
                  maxLength: 4000,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Private note · only you',
                  ),
                ),
              const Text('Lists'),
              Wrap(
                spacing: 8,
                children: [
                  if (_space == Places.personal)
                    FilterChip(
                      label: const Text('Saved places'),
                      selected: _lists.contains(Places.saved),
                      onSelected: (v) => setState(() {
                        v
                            ? _lists.add(Places.saved)
                            : _lists.remove(Places.saved);
                      }),
                    ),
                  for (final list in places.lists.where(
                    (e) => e.space == _space,
                  ))
                    FilterChip(
                      label: Text(list.name),
                      selected: _lists.contains(list.id),
                      onSelected: (v) => setState(() {
                        v ? _lists.add(list.id) : _lists.remove(list.id);
                      }),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('New list'),
                    onPressed: () async {
                      final list = await createPlaceList(
                        context,
                        places,
                        scope: _space,
                      );
                      if (list != null && mounted) {
                        setState(() {
                          _space = list.space;
                          _lists.add(list.id);
                        });
                      }
                    },
                  ),
                ],
              ),
              if (_space != Places.personal)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'The name, emoji, coordinates and shared note are visible to this group. Your private note stays with you.',
                  ),
                ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.entry != null && _editable)
          TextButton(
            onPressed: _saving
                ? null
                : () async {
                    if (!await _confirm(
                      context,
                      'Delete this place?',
                      'This removes it from every list in ${places.scopeName(_space)}.',
                    )) {
                      return;
                    }
                    setState(() => _saving = true);
                    try {
                      await places.remove(widget.entry!);
                      if (context.mounted) Navigator.pop(context, widget.entry);
                    } catch (e) {
                      if (mounted) {
                        setState(() {
                          _saving = false;
                          _error = '$e';
                        });
                      }
                    }
                  },
            child: const Text('Delete'),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Give this place a name.');
      return;
    }
    if (_lists.isEmpty && widget.entry == null) {
      setState(() => _error = 'Choose or create a list.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final places = widget.places;
      var entry = widget.entry;
      final old = entry == null ? <String>{} : places.listsOf(entry).toSet();
      if (entry == null) {
        entry = await places.save(
          lat: widget.lat,
          lng: widget.lng,
          name: _name.text,
          emoji: _emoji.text,
          note: _note.text,
          space: _space,
          list: _lists.first,
          id: _draftId,
        );
        old.add(_lists.first);
      } else if (_editable) {
        entry = await places.edit(
          entry,
          name: _name.text,
          emoji: _emoji.text,
          note: _note.text,
        );
      }
      for (final id in {...old, ..._lists}) {
        if (old.contains(id) != _lists.contains(id)) {
          await places.setInList(entry, id, _lists.contains(id));
        }
      }
      if (_space != Places.personal &&
          _private.text.trim() != places.privateNote(entry)) {
        await places.setPrivateNote(entry, _private.text);
      }
      if (mounted) Navigator.pop(context, entry);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }
}
