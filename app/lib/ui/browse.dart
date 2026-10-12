part of 'app.dart';

/// Finding public forums and chats: what friends follow (see [Listings]),
/// and starting or joining one by its name.
extension _BrowsePages on _OurNetAppState {
  /// Public spaces friends follow that this device has not joined.
  List<Listing> suggestions(String type, {String query = ''}) => [
    for (final l in listings.search(query))
      if (l.type == type && !node.subscriptions.contains(l.space)) l,
  ];

  /// Joins the public space [space] and tells friends it is followed.
  Future<void> joinListed(Listing l) async {
    if (l.type == 'chat') {
      await publicChats.join(l.space);
    } else {
      await notes.state.subscribe(l.space, true);
    }
    // The friends who follow it are the ones to catch up from.
    if (network.running) unawaited(network.syncAll());
    unawaited(listings.refresh());
  }

  /// A short "friends follow" list for the bottom of a forums or chats list:
  /// the most followed few, and a way to see the rest.
  Widget suggestedSpaces(BuildContext context, String type) {
    final all = suggestions(type);
    if (all.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final noun = type == 'chat' ? 'chats' : 'forums';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Friends follow',
            style: theme.textTheme.labelLarge,
          ),
        ),
        for (final l in all.take(5)) listedTile(context, l),
        if (all.length > 5)
          ListTile(
            leading: const Icon(Icons.travel_explore),
            title: Text('Browse all $noun (${all.length})'),
            onTap: () => act(() => browseSpaces(context, type)),
          ),
      ],
    );
  }

  Widget listedTile(BuildContext context, Listing l) {
    final friends = l.people.length;
    final detail = [
      friends == 1 ? '1 friend' : '$friends friends',
      if (l.description.isNotEmpty) l.description,
    ].join(' · ');
    return ListTile(
      leading: Icon(l.type == 'chat' ? Icons.public : Icons.forum_outlined),
      title: Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: FilledButton.tonal(
        onPressed: busy
            ? null
            : () => act(() async {
                await joinListed(l);
                if (l.type == 'chat') {
                  openPublicChat(l.space);
                } else {
                  openForum(l.space);
                }
              }),
        child: const Text('Join'),
      ),
    );
  }

  /// A searchable list of everything friends follow of one [type], with a
  /// field that also takes a name, address or link to go straight to.
  Future<void> browseSpaces(BuildContext context, String type) async {
    final query = TextEditingController();
    final noun = type == 'chat' ? 'chat' : 'forum';
    final picked = await showDialog<Object>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, change) {
          final text = query.text.trim();
          final found = suggestions(type, query: text);
          return AlertDialog(
            title: Text('Public ${noun}s'),
            content: SizedBox(
              width: 440,
              height: 420,
              child: Column(
                children: [
                  TextField(
                    controller: query,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: 'Search, or type a $noun name',
                      prefixIcon: const Icon(Icons.search),
                    ),
                    onChanged: (_) => change(() {}),
                    onSubmitted: (_) {
                      if (text.isNotEmpty) Navigator.pop(dialog, text);
                    },
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: found.isEmpty
                        ? Center(
                            child: Text(
                              text.isEmpty
                                  ? 'No ${noun}s from friends yet. Type a name to start or join one.'
                                  : 'No friends follow "$text". Press enter to start or join it.',
                              textAlign: TextAlign.center,
                            ),
                          )
                        : ListView(
                            children: [
                              for (final l in found)
                                ListTile(
                                  title: Text(l.name),
                                  subtitle: Text(
                                    [
                                      l.people.length == 1
                                          ? '1 friend'
                                          : '${l.people.length} friends',
                                      if (l.description.isNotEmpty)
                                        l.description,
                                    ].join(' · '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: const Text('Join'),
                                  onTap: () => Navigator.pop(dialog, l),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
    // The dialog may still be animating out with the field in it.
    Future<void>.delayed(const Duration(seconds: 1), query.dispose);
    if (picked == null || !context.mounted) return;
    if (picked is Listing) {
      await joinListed(picked);
      if (picked.type == 'chat') {
        openPublicChat(picked.space);
      } else {
        openForum(picked.space);
      }
    } else if (picked is String) {
      if (type == 'chat') {
        await joinPublicChat(context, typed: picked);
      } else {
        await joinForum(context, typed: picked);
      }
    }
  }

  /// A forum or chat link was tapped: joins the space if need be, then opens
  /// the forum, post or chat.
  Future<void> followObjectLink(ObjectLink link) async {
    // Links can sit on pages above the app's own, such as a note.
    noteNavigator.currentState?.popUntil((route) => route.isFirst);
    final isChat = link.type == 'message';
    try {
      if (isChat) {
        if (!publicChats.joined.contains(link.space)) {
          await publicChats.join(link.space);
        }
      } else if (!node.subscriptions.contains(link.space)) {
        await notes.state.subscribe(link.space, true);
      }
    } catch (e) {
      notice('Could not join: $e');
      return;
    }
    if (network.running) unawaited(network.syncAll());
    unawaited(listings.refresh());
    if (isChat) {
      openPublicChat(link.space);
      return;
    }
    openForum(link.space);
    final id = link.object;
    if (id == null) return;
    // A post opens its discussion: the top of the thread it is in.
    final root = threadRoot(id);
    if (root == null) {
      notice('That post has not reached this device yet');
      return;
    }
    update(() => selectedThread = root);
  }

  /// The first post of the discussion [post] is in, or null if this device
  /// does not hold it.
  String? threadRoot(String post) {
    var id = post;
    for (var hops = 0; hops < 1000; hops++) {
      final o = node.store.get(id);
      if (o == null) return hops == 0 ? null : id;
      final payload = o.data['payload'];
      final parent = payload is Json ? payload['parent'] : null;
      if (parent is! String) return id;
      id = parent;
    }
    return id;
  }
}
