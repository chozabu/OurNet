part of 'app.dart';

class _SearchHit {
  final EverydayItem item;
  final String scope;
  final String source;
  final EverydayItem? room;
  _SearchHit(this.item, this.scope, this.source, [this.room]);
}

extension _DiscoveryPages on _OurNetAppState {
  Future<List<_SearchHit>> buildSearchIndex() async {
    final result = <_SearchHit>[];
    final everyday = Everyday(node);
    for (final item in await everyday.items()) {
      if (item.data['deleted'] != true && item.data['type'] != 'pin') {
        result.add(_SearchHit(item, 'Notes', 'Notes · Only you'));
      }
    }
    for (final item in await notes.summaries()) {
      result.add(
        _SearchHit(
          item,
          'Notes',
          item.data['members'] > 1
              ? 'Notes · ${item.data['members']} collaborators'
              : 'Notes · Only you',
        ),
      );
    }
    for (final room in await everyday.rooms()) {
      if (room.data['note'] == true) continue;
      for (final item in await everyday.items(room)) {
        if (item.data['deleted'] != true && item.data['type'] != 'pin') {
          result.add(
            _SearchHit(
              item,
              'Groups',
              '${room.data['name']} · Private group',
              room,
            ),
          );
        }
      }
    }
    for (final entry in await Drive(node).entries()) {
      if (!entry.current.deleted) {
        result.add(
          _SearchHit(
            EverydayItem(entry.current.object, entry.current.data),
            'Files',
            'Private drive · Only you',
          ),
        );
      }
    }
    // Newest first in pages: searching reads as much history as it needs
    // rather than a fixed slice of it, and holds only the page.
    await for (final object in scanHistory(const ['message', 'post', 'file'])) {
      if (!contentVisible(object)) continue;
      final payload = await node.content(object);
      if (payload == null) continue;
      result.add(
        _SearchHit(
          EverydayItem(object, payload),
          object.kind == 'message'
              ? 'Messages'
              : object.kind == 'post'
              ? 'Forums'
              : 'Files',
          object.kind == 'message'
              ? 'Direct messages · ${name(object.author == node.person ? object.audience.where((p) => p != node.person).firstOrNull ?? node.person : object.author)}'
              : '${object.space} · Public',
        ),
      );
    }
    result.sort(
      (a, b) => b.item.object.created.compareTo(a.item.object.created),
    );
    return result;
  }

  Future<void> openSource(EverydayItem item, [EverydayItem? room]) async {
    if (item.data['type'] == 'shared_note') {
      await openNote(item.data['entry']);
      return;
    }
    final o = item.object;
    if (o.kind == 'room_item' && room == null) {
      room = (await Everyday(
        node,
      ).rooms()).where((r) => r.object.space == o.space).firstOrNull;
    }
    update(() {
      if (o.kind == 'inbox') {
        activeRoom = null;
        notesController.notesFilter = item.data['type'] == 'file'
            ? 'Files'
            : item.data['type'] == 'check'
            ? 'Lists'
            : 'All';
        tab = Destination.notes;
      } else if (o.kind == 'room_item' && room != null) {
        activeRoom = room;
        tab = Destination.groups;
        everydaySection = item.data['type'] == 'file'
            ? 'Files'
            : item.data['type'] == 'check'
            ? 'Lists'
            : 'Conversation';
      } else if (o.kind == 'message') {
        tab = Destination.messages;
        showConversation = true;
        contact = o.author == node.person
            ? o.audience.where((p) => p != node.person).firstOrNull
            : o.author;
      } else if (o.kind == 'post') {
        tab = Destination.forums;
        space = o.space;
        selectedThread = item.data['parent'] ?? o.id;
        showForum = true;
      } else {
        tab = Destination.files;
        attachmentFiles = false;
        publicFiles = o.isPublic;
        driveFolder = item.data['folder'];
        fileQuery = '';
        fileSearch.clear();
      }
    });
  }

  Widget searchPage(BuildContext context) => Column(
    children: [
      TextField(
        controller: search,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Search your notes, conversations and files',
          prefixIcon: Icon(Icons.search),
        ),
        onChanged: (_) => update(() {}),
      ),
      const SizedBox(height: 12),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final scope in [
              'All',
              'Notes',
              'Messages',
              'Groups',
              'Forums',
              'Files',
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(scope),
                  selected: searchScope == scope,
                  onSelected: (_) => update(() => searchScope = scope),
                ),
              ),
          ],
        ),
      ),
      Expanded(
        child: FutureBuilder<List<_SearchHit>>(
          future: searchIndex ??= buildSearchIndex(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return empty(
                'Search could not load',
                'Try reopening Search.',
                Icons.error_outline,
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final query = search.text.trim().toLowerCase();
            final hits = snapshot.data!
                .where(
                  (hit) =>
                      (searchScope == 'All' ||
                          searchScope == hit.scope ||
                          searchScope == 'Files' &&
                              hit.item.data['chunks'] is List) &&
                      '${hit.item.data['title'] ?? ''} ${hit.item.data['text'] ?? ''} ${hit.item.data['name'] ?? ''} ${hit.source}'
                          .toLowerCase()
                          .contains(query),
                )
                .toList();
            if (hits.isEmpty) {
              return empty(
                'No matches',
                'Try a different word or search all destinations.',
                Icons.search_off,
              );
            }
            return ListView.builder(
              itemCount: hits.length,
              itemBuilder: (context, index) {
                final hit = hits[index], p = hits[index].item.data;
                return ListTile(
                  leading: isImagePayload(p)
                      ? InlineImage(
                          key: ValueKey(hit.item.object.id),
                          files: files,
                          object: hit.item.object,
                          payload: p,
                          online: network.running,
                          thumbnail: true,
                        )
                      : Icon(
                          p['chunks'] is List
                              ? Icons.insert_drive_file_outlined
                              : Icons.notes,
                        ),
                  title: Text(
                    p['title'] ?? p['name'] ?? p['text'] ?? 'Item',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(hit.source),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => openSource(hit.item, hit.room),
                );
              },
            );
          },
        ),
      ),
    ],
  );
}
