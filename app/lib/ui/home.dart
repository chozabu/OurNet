part of 'app.dart';

extension _HomePages on _OurNetAppState {
  Future<void> addFriend(BuildContext context) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FriendInvitePage(
          network: network,
          enablePlatform: widget.enablePlatform,
        ),
      ),
    );
    refresh();
  }

  Widget recentActivity(List<SignedObject> objects, String fallback) {
    final visible = objects.where(node.visible).toList()
      ..sort((a, b) => b.created.compareTo(a.created));
    if (visible.isEmpty) return Text(fallback);
    final latest = visible.first;
    return FutureBuilder<Json?>(
      future: node.content(latest),
      builder: (context, snapshot) {
        final content = snapshot.data;
        final body = (content?['text'] ?? '').toString();
        final preview =
            content?['title'] ??
            (body.isNotEmpty ? body : content?['name'] ?? fallback);
        final time = DateTime.fromMillisecondsSinceEpoch(
          latest.created,
        ).toLocal().toString().substring(0, 16);
        return Text(
          '$preview\n$time',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }

  Widget browsePane(
    BuildContext context, {
    required Widget list,
    required Widget detail,
    required bool selected,
    required VoidCallback back,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth >= 760) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 260, child: list),
            const VerticalDivider(width: 25),
            Expanded(child: detail),
          ],
        );
      }
      return selected
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextButton.icon(
                  onPressed: back,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Back to list'),
                ),
                Expanded(child: detail),
              ],
            )
          : list;
    },
  );

  Widget groupsPage(BuildContext context) => FutureBuilder<List<EverydayItem>>(
    future: roomsView ??= Everyday(node).rooms(),
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return empty(
          'Groups could not be loaded',
          'Try opening Private groups again.',
          Icons.error_outline,
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
        final rooms = snapshot.data!.where((r) => r.data['note'] != true).toList();
      if (activeRoom != null &&
          snapshot.connectionState == ConnectionState.done) {
        final previousRoom = activeRoom!.object.id;
        activeRoom = rooms
            .where((r) => r.object.space == activeRoom!.object.space)
            .firstOrNull;
        if (previousRoom != activeRoom?.object.id) everydayView = null;
      }
      return browsePane(
        context,
        selected: activeRoom != null,
        back: () => update(() => activeRoom = null),
        list: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () => act(() => createPrivateGroup(context)),
              icon: const Icon(Icons.add),
              label: const Text('Create group'),
            ),
            TextButton.icon(
              onPressed: busy ? null : () => act(() => addFriend(context)),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add friend'),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: rooms.isEmpty
                  ? empty(
                      'Your people, together',
                      'Create a private group for conversations, files and lists.',
                      Icons.people_outline,
                    )
                  : ListView(
                      children: [
                        for (final room in rooms)
                          ListTile(
                            leading: const Icon(Icons.lock_outline),
                            title: Text(room.data['name']),
                            subtitle: recentActivity(
                              objectsBySpace('room_item')[room.data['room']] ??
                                  const [],
                              '${room.object.audience.length} members · Private',
                            ),
                            trailing: unreadBadge(
                              unreadObjects(
                                'room_item',
                              ).where((o) => o.space == room.data['room']),
                            ),
                            selected: activeRoom?.object.id == room.object.id,
                            onTap: () => update(() {
                              for (final item
                                  in node.store
                                      .objects(kind: 'room_item')
                                      .where(
                                        (o) => o.space == room.data['room'],
                                      )) {
                                node.store.set('seen/${item.id}', true);
                              }
                              activeRoom = room;
                              everydaySection = 'Conversation';
                            }),
                          ),
                      ],
                    ),
            ),
          ],
        ),
        detail: activeRoom == null
            ? empty(
                'Private groups',
                'Choose a group or create one for your people.',
                Icons.people_outline,
              )
            : everydayPage(context),
      );
    },
  );
}
