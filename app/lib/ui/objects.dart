part of 'app.dart';

extension _ObjectsPages on _OurNetAppState {
  Widget objectList(
    BuildContext context,
    List<SignedObject> objects, {
    ScrollController? controller,

    /// Set for a private group's forum, which keeps its own open discussion
    /// and reply target; otherwise the public forum's are used.
    ForumScope? forum,

    /// The reply box of an open discussion, which opens under the post it
    /// answers instead of at the bottom of the page.
    InlineReply? inline,
  }) {
    final thread = forum != null ? forum.thread : selectedThread;
    objects = objects.where(contentVisible).toList();
    if (objects.isEmpty) {
      return empty(
        'Nothing here yet',
        'New content appears when it is shared and synchronised.',
        Icons.notes,
      );
    }
    // An open discussion reads as a tree: compact rows with thread lines,
    // whose branches can be folded.
    final rows =
        thread != null &&
            objects.every((o) => o.kind == 'post' || o.kind == 'room_post')
        ? threadRows(
            objects,
            (o) => forum?.depth(o) ?? replyDepth(o),
            collapsedPosts,
          )
        : null;
    final levels = MediaQuery.sizeOf(context).width < 600 ? 5 : 12;
    // If the post being answered is folded away, the box shows under the
    // first post rather than vanishing.
    final answering = rows == null || inline == null
        ? null
        : rows.any((r) => r.object.id == inline.target)
        ? inline.target
        : rows.first.object.id;
    return ListView.builder(
      controller: controller,
      key: PageStorageKey(
        forum?.key ?? 'objects/$tab/$contact/$space/$selectedThread',
      ),
      padding: rows == null ? null : const EdgeInsets.symmetric(horizontal: 4),
      itemCount: rows?.length ?? objects.length,
      itemBuilder: (context, index) {
        final row = rows?[index];
        final o = row?.object ?? objects[index];
        return FutureBuilder<Json?>(
          future: node.content(o),
          builder: (context, snapshot) {
            final p = snapshot.data;
            if (p == null) return const SizedBox.shrink();
            final isPost = o.kind == 'post' || o.kind == 'room_post';
            // Forum history shared with a new member is republished by the
            // group's owner; the person who wrote it is named in the post.
            final author = o.kind == 'room_post' && p['history'] == true
                ? (p['originalAuthor'] as String? ?? o.author)
                : o.author;
            final written = DateTime.fromMillisecondsSinceEpoch(
              o.kind == 'room_post'
                  ? p['sent'] as int? ?? o.created
                  : o.created,
            );
            final unread =
                author != node.person &&
                node.store.setting(
                      '${o.kind == 'message' ? 'read' : 'seen'}/${o.id}',
                    ) !=
                    true;
            if (row != null) {
              return ForumComment(
                key: ValueKey('comment/${o.id}'),
                id: o.id,
                depth: row.depth,
                ancestors: row.ancestors,
                through: row.through,
                author: name(author),
                initial: name(author).substring(0, 1),
                written: written,
                unread: unread,
                collapsed: row.collapsed,
                hasChildren: row.hasChildren,
                hidden: row.hidden,
                maxLevels: levels,
                title: p['title'] as String?,
                scope: row.depth == 0 ? scopeLabel(o) : null,
                onToggle: toggleCollapsed,
                replying: answering == o.id,
                reply: answering == o.id ? inline!.box(context) : null,
                onReply: () => answerPost(forum, o.id),
                menu: postMenu(
                  o,
                  author,
                  child: const SizedBox(
                    width: 32,
                    height: 28,
                    child: Icon(Icons.more_horiz, size: 18),
                  ),
                  provenanceItem: true,
                  copy: p['text'] as String?,
                ),
                body: [
                  if (isImagePayload(p))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: postImage(o, p),
                    ),
                  if ((p['text'] ?? '').toString().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: SelectionArea(child: MessageText(p['text'])),
                    ),
                  ...postAttachment(context, o, p),
                ],
              );
            }
            // In a forum's list of discussions the whole card opens the
            // discussion, so it needs no reply or download buttons.
            final listed = isPost && thread == null;
            final replies = forum?.replies(o) ?? replyCounts()[o.id] ?? 0;
            final small = Theme.of(context).textTheme.bodySmall;
            final card = Card(
              clipBehavior: Clip.antiAlias,
              color: unread
                  ? Theme.of(context).colorScheme.secondaryContainer
                  : null,
              margin: EdgeInsets.only(
                top: 6,
                bottom: 6,
                left: isPost && thread != null
                    ? (forum?.depth(o) ?? replyDepth(o)).clamp(0, 4) * 16.0
                    : 0,
              ),
              child: InkWell(
                onTap: !listed
                    ? null
                    : forum != null
                    ? () => forum.open(o.id)
                    : () => update(() {
                        // From the all-forums view, the discussion opens in
                        // the forum it belongs to.
                        if (space == _OurNetAppState.allForums) space = o.space;
                        selectedThread = o.id;
                        replyTo = null;
                      }),
                child: Padding(
                  padding: EdgeInsets.all(listed ? 12 : 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 15,
                            child: Text(name(author).substring(0, 1)),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                text: name(author),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                                children: [
                                  if (listed &&
                                      forum == null &&
                                      space == _OurNetAppState.allForums)
                                    TextSpan(
                                      text: ' · ${forumName(o.space)}',
                                      style: small?.copyWith(
                                        fontWeight: FontWeight.normal,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                    ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            written.toLocal().toString().substring(0, 16),
                            style: small,
                          ),
                          if (isPost) postMenu(o, author),
                          IconButton(
                            tooltip: 'Inspect provenance',
                            onPressed: () => provenance(context, o),
                            icon: const Icon(Icons.verified_outlined, size: 20),
                          ),
                        ],
                      ),
                      if (isPost && p['title'] != null)
                        Padding(
                          padding: EdgeInsets.only(top: listed ? 6 : 12),
                          child: Text(
                            p['title'],
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                      if (isImagePayload(p))
                        Padding(
                          padding: EdgeInsets.symmetric(
                            vertical: listed ? 6 : 12,
                          ),
                          child: postImage(o, p),
                        ),
                      if (p['parent'] != null)
                        Text(
                          'Reply to ${short(p['parent'])}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if ((p['text'] ?? '').toString().isNotEmpty)
                        Padding(
                          padding: EdgeInsets.symmetric(
                            vertical: listed ? 6 : 12,
                          ),
                          child: listed
                              ? Text(p['text'])
                              : SelectableText(p['text']),
                        ),
                      if (!listed) ...postAttachment(context, o, p),
                      if (listed && p['chunks'] != null && !isImagePayload(p))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text('📎 ${p['name']} · ${p['size']} bytes'),
                        ),
                      if (listed)
                        Text(
                          '$replies ${replies == 1 ? 'reply' : 'replies'} · ${scopeLabel(o)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: small,
                        ),
                      if (!listed)
                        Wrap(
                          spacing: 8,
                          children: [
                            if (o.kind == 'message' && o.author != node.person)
                              TextButton(
                                onPressed: () => act(() => node.markRead(o.id)),
                                child: Text(
                                  node.store.setting('read/${o.id}') == true
                                      ? 'Read'
                                      : 'Mark read',
                                ),
                              ),
                            if (o.kind == 'message' && o.author == node.person)
                              Text(
                                delivery(o, attachment: p['chunks'] is List),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            Text(
                              scopeLabel(o),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            );
            return card;
          },
        );
      },
    );
  }

  /// Chooses [id] as the post to answer, and puts the cursor in the reply box
  /// once it has moved there.
  void answerPost(ForumScope? forum, String id) {
    if (forum != null) {
      forum.reply(id);
    } else {
      update(() {
        selectedThread ??= id;
        replyTo = id;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => composerFocus.requestFocus(),
    );
  }

  String scopeLabel(SignedObject o) => o.isPublic
      ? 'Public'
      : o.kind == 'room_post'
      ? 'Encrypted · group members'
      : 'Encrypted · selected people';

  void toggleCollapsed(String id) => update(() {
    if (!collapsedPosts.remove(id)) collapsedPosts.add(id);
  });

  Widget postImage(SignedObject o, Json p) => InlineImage(
    key: ValueKey(o.id),
    files: files,
    object: o,
    payload: p,
    online: network.running,
  );

  /// The download button for a post's attached file, and its last error.
  List<Widget> postAttachment(BuildContext context, SignedObject o, Json p) => [
    if (p['chunks'] != null)
      OutlinedButton.icon(
        onPressed: fileProgress.containsKey(o.id)
            ? null
            : () => saveFile(context, o, p),
        icon: const Icon(Icons.download),
        label: Text(
          fileProgress.containsKey(o.id)
              ? '${p['name']} · preparing ${(fileProgress[o.id]! * 100).round()}%'
              : fileErrors.containsKey(o.id)
              ? '${p['name']} · Retry download'
              : '${p['name']} · ${p['size']} bytes',
        ),
      ),
    if (fileErrors[o.id] case final error?)
      Text('$error · Verified chunks are kept for retry.'),
  ];

  /// Hide, block and remove actions for a post; [provenanceItem] adds the
  /// provenance dialog for lists that have no separate button for it.
  Widget postMenu(
    SignedObject o,
    String author, {
    Widget? child,
    bool provenanceItem = false,
    String? copy,
  }) => PopupMenuButton<String>(
    tooltip: 'Discussion options',
    child: child,
    onSelected: (action) {
      if (action == 'hide') {
        node.store.set('hidden/${o.id}', true);
        searchIndex = null;
        refresh();
      }
      if (action == 'block') {
        node.block(author, true);
        searchIndex = null;
        refresh();
      }
      if (action == 'moderate') {
        act(() async {
          await node.publish('forum_hide', {'object': o.id}, space: o.space);
        });
      }
      if (action == 'provenance') provenance(context, o);
      if (action == 'copy') Clipboard.setData(ClipboardData(text: copy!));
    },
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'hide', child: Text('Hide for me')),
      if (author != node.person)
        const PopupMenuItem(value: 'block', child: Text('Block author')),
      if (ownsForum(o.space))
        const PopupMenuItem(
          value: 'moderate',
          child: Text('Remove from forum'),
        ),
      if (copy != null && copy.isNotEmpty)
        const PopupMenuItem(value: 'copy', child: Text('Copy text')),
      if (provenanceItem)
        const PopupMenuItem(
          value: 'provenance',
          child: Text('Inspect provenance'),
        ),
    ],
  );

  String delivery(SignedObject o, {bool attachment = false}) {
    if (node.store.setting('readBy/${o.id}') != null) {
      return attachment
          ? 'Seen by recipient · original can be downloaded'
          : 'Read by recipient';
    }
    final receipts = node.store
        .evidence(o.id)
        .where(
          (e) =>
              e.data['domain'] == 'ournet/receipt/2' &&
              o.audience.contains(e.certificate.person) &&
              e.certificate.person != node.person,
        );
    final helperAccepted = node.store
        .evidence(o.id)
        .any(
          (e) =>
              e.data['domain'] == 'ournet/receipt/2' &&
              e.certificate.device != node.identity.device &&
              ((o.data['via'] as List).contains(e.certificate.person) ||
                  e.certificate.person == node.person),
        );
    return receipts.isEmpty && helperAccepted
        ? attachment
              ? 'Attachment details stored on another device · original still needs a source'
              : 'Stored by a forwarding device · waiting for recipient'
        : receipts.isEmpty
        ? (network.running
              ? 'Saved here · waiting for recipient'
              : 'Saved here · sends when connected')
        : attachment
        ? 'Shared · original available to download'
        : 'Delivered to recipient';
  }

  Future<void> provenance(
    BuildContext context,
    SignedObject o,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Origin & recorded handoffs'),
      content: SizedBox(
        width: 650,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                'Object: ${o.id}\nAuthor: ${o.author}\nDevice: ${o.certificate.label}\nScope: ${o.isPublic ? 'Public' : o.audience.map(name).join(', ')}',
              ),
              const Divider(),
              const Text(
                'These signatures attest to recorded actions. They do not prove truth, endorsement or an exhaustive history outside OurNet.',
              ),
              ...node.store
                  .evidence(o.id)
                  .map(
                    (e) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        e.data['domain'] == 'ournet/receipt/2'
                            ? Icons.done_all
                            : Icons.forward,
                      ),
                      title: Text(
                        '${name(e.certificate.person)} · ${e.data['domain'] == 'ournet/receipt/2' ? 'acknowledged receipt' : 'authorised handoff'}',
                      ),
                      subtitle: Text(short(e.id)),
                    ),
                  ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
  void pickFile(
    List<String> audience, {
    Json? driveData,
    String? postSpace,
    Json? postData,
  }) => act(() async {
    final draftKey = composerContext;
    final submitted = composer.text;
    final isMessage = tab == Destination.messages;
    final result = await FilePicker.pickFile();
    if (result == null) return;
    if ((result.lengthSync() ?? 0) > Files.maxSize) {
      throw StateError('Prototype file limit is 64 MiB');
    }
    final path = result.path;
    if (path != null) {
      await files.publish(
        path,
        audience: audience,
        text: isMessage ? submitted : '',
        drive: driveData,
        postSpace: postSpace,
        post: postData,
      );
    } else {
      final temp = File(
        '${(await getTemporaryDirectory()).path}/${randomId()}.upload',
      );
      final output = temp.openWrite();
      try {
        var size = 0;
        await for (final bytes in result.readAsByteStream()) {
          size += bytes.length;
          if (size > Files.maxSize) {
            throw StateError('Prototype file limit is 64 MiB');
          }
          output.add(bytes);
          await output.flush();
        }
        await output.close();
        await files.publish(
          temp.path,
          name: result.name,
          audience: audience,
          drive: driveData,
          postSpace: postSpace,
          post: postData,
          text: isMessage ? submitted : '',
        );
      } finally {
        await output.close();
        if (await temp.exists()) await temp.delete();
      }
    }
    if (isMessage || postSpace != null) await finishDraft(draftKey, submitted);
  });
  void previewImage(BuildContext context, SignedObject object) => act(() async {
    final image = Uint8List.fromList(
      await files.readBytes(object, limit: Files.maxSize),
    );
    if (!context.mounted) return;
    await showImageViewer(context, bytes: Future.value(image));
  });
  Future<void> saveFile(
    BuildContext context,
    SignedObject o,
    Json payload,
  ) async {
    if (fileProgress.containsKey(o.id)) return;
    if (fileProgress.length >= 2) {
      notice('Two files are already being prepared. Retry when one finishes.');
      return;
    }
    update(() {
      fileProgress[o.id] = 0;
      fileErrors.remove(o.id);
    });
    File? temp;
    final progressClock = Stopwatch()..start();
    var lastUpdate = -100;
    try {
      temp = File(
        '${(await getTemporaryDirectory()).path}/${o.id}.${randomId()}.download',
      );
      await files.save(
        o,
        temp.path,
        onProgress: (done, total) {
          if (done == total ||
              progressClock.elapsedMilliseconds - lastUpdate >= 100) {
            lastUpdate = progressClock.elapsedMilliseconds;
            update(() => fileProgress[o.id] = total == 0 ? 1 : done / total);
          }
        },
      );
      if (!mounted) return;
      final destination = await FilePicker.saveFile(
        fileName: payload['name'],
        bytes: await temp.readAsBytes(),
      );
      if (destination != null) notice('File saved');
    } catch (error) {
      update(() => fileErrors[o.id] = 'Download interrupted: $error');
    } finally {
      try {
        if (temp != null && await temp.exists()) await temp.delete();
      } finally {
        update(() => fileProgress.remove(o.id));
      }
    }
  }

  Widget publicFilePage(BuildContext context) => Column(
    children: [
      Row(
        children: [
          const Expanded(
            child: Text(
              'Files shared with your network',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
          ),
          FilledButton.icon(
            onPressed: () => pickFile([]),
            icon: const Icon(Icons.upload_file),
            label: const Text('Publish file'),
          ),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Subscribe to public files'),
        value: node.subscriptions.contains('files'),
        onChanged: (v) => act(() => notes.state.subscribe('files', v)),
      ),
      Expanded(child: objectList(context, publicFileObjects())),
    ],
  );
}

/// Where the reply box of an open discussion goes: [target] is the id of the
/// post being answered, and [box] builds the box itself.
class InlineReply {
  final String target;
  final Widget Function(BuildContext) box;
  const InlineReply(this.target, this.box);
}

/// What a private group's forum needs from [objectList] beyond the posts:
/// where it is in its discussions, and how to move around them.
class ForumScope {
  final String key;
  final String? thread;
  final int Function(SignedObject) depth;
  final int Function(SignedObject) replies;
  final void Function(String id) open;
  final void Function(String id) reply;
  const ForumScope({
    required this.key,
    required this.thread,
    required this.depth,
    required this.replies,
    required this.open,
    required this.reply,
  });
}
