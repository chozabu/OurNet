part of 'app.dart';

/// A private group's Notes section: the same notes screen as a person's own,
/// showing the notes kept in the group's space for everyone in it.
extension _GroupNotes on _OurNetAppState {
  /// Looks once per group for lists made before groups had notes, so they can
  /// be offered for import. They were group items, so this reads the group.
  void ensureGroupListScan(EverydayItem room) {
    final id = room.object.space;
    if (groupLists.containsKey(id)) return;
    groupLists[id] = const [];
    unawaited(() async {
      try {
        final items = await Everyday(node).items(room);
        groupLists[id] = [
          for (final i in items)
            if (i.data['type'] == 'check' && i.data['deleted'] != true) i,
        ];
      } catch (_) {
        groupLists.remove(id);
      }
      if (mounted) update(() {});
    }());
  }

  Widget groupNotesView(BuildContext context, EverydayItem room) {
    ensureGroupListScan(room);
    final lists = groupLists[room.object.space] ?? const <EverydayItem>[];
    final names = {for (final i in lists) i.data['list']};
    return Column(
      children: [
        if (lists.isNotEmpty)
          Card(
            margin: const EdgeInsets.only(top: 8),
            child: ListTile(
              leading: const Icon(Icons.checklist),
              title: Text(
                names.length == 1
                    ? 'This group has a list from before notes'
                    : 'This group has ${names.length} lists from before notes',
              ),
              subtitle: const Text(
                'Import them as group notes. Lists are now checklists inside notes.',
              ),
              trailing: FilledButton(
                onPressed: busy
                    ? null
                    : () => act(() => importGroupLists(room)),
                child: const Text('Import'),
              ),
            ),
          ),
        Expanded(child: notesHome(context)),
      ],
    );
  }

  /// Turns each of the group's old lists into a group note holding its items,
  /// then removes the old items. A list can be imported again after an
  /// interruption: its note has a fixed ID, so it is not duplicated.
  Future<void> importGroupLists(EverydayItem room) async {
    final space = room.object.space;
    final byList = <String, List<EverydayItem>>{};
    for (final item in groupLists[space] ?? const <EverydayItem>[]) {
      (byList['${item.data['list']}'] ??= []).add(item);
    }
    for (final entry in byList.entries) {
      final checks = [...entry.value]
        ..sort(
          (a, b) => (a.data['clock'] as int).compareTo(b.data['clock'] as int),
        );
      // A note holds up to 200 items.
      for (var from = 0; from < checks.length; from += Notes.maxChecks) {
        final part = checks.skip(from).take(Notes.maxChecks).toList();
        final suffix = from == 0 ? '' : ' (${from ~/ Notes.maxChecks + 1})';
        final note = await notes.create(
          group: space,
          title: Notes.bounded('${entry.key}$suffix', 100),
          items: [for (final c in part) '${c.data['text']}'],
          stableId: 'list-${part.first.data['entry']}',
        );
        final changes = <NoteChange>[
          for (final (i, id) in note.checks.indexed)
            if (i < part.length && part[i].data['done'] == true)
              (field: 'check:$id:done', value: true, parents: const <String>[]),
        ];
        if (changes.isNotEmpty) {
          await notes.apply(note.id, note.epoch, changes);
        }
      }
      for (final item in checks) {
        await Everyday(node).write({...item.data, 'deleted': true}, room: room);
      }
    }
    groupLists[space] = const [];
    everydayView = null;
    if (mounted) update(() {});
    notice('Lists imported as notes');
  }
}
