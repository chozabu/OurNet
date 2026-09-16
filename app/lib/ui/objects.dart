part of 'app.dart';

extension _ObjectsPages on _OurNetAppState {
  Widget objectList(
    BuildContext context,
    List<SignedObject> objects, {
    ScrollController? controller,
  }) {
    objects = objects.where(contentVisible).toList();
    if (objects.isEmpty) {
      return empty(
        'Nothing here yet',
        'New content appears when it is shared and synchronised.',
        Icons.notes,
      );
    }
    return ListView.builder(
      controller: controller,
      key: PageStorageKey('objects/$tab/$contact/$space/$selectedThread'),
      itemCount: objects.length,
      itemBuilder: (context, index) {
        final o = objects[index];
        return FutureBuilder<Json?>(
          future: node.content(o),
          builder: (context, snapshot) {
            final p = snapshot.data;
            if (p == null) return const SizedBox.shrink();
            return Card(
              color:
                  o.author != node.person &&
                      node.store.setting(
                            '${o.kind == 'message' ? 'read' : 'seen'}/${o.id}',
                          ) !=
                          true
                  ? Theme.of(context).colorScheme.secondaryContainer
                  : null,
              margin: EdgeInsets.only(
                top: 6,
                bottom: 6,
                left: o.kind == 'post' && selectedThread != null
                    ? replyDepth(o).clamp(0, 4) * 16.0
                    : 0,
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 15,
                          child: Text(name(o.author).substring(0, 1)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            name(o.author),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Text(
                          DateTime.fromMillisecondsSinceEpoch(
                            o.created,
                          ).toLocal().toString().substring(0, 16),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (o.kind == 'post')
                          PopupMenuButton<String>(
                            tooltip: 'Discussion options',
                            onSelected: (action) {
                              if (action == 'hide') {
                                node.store.set('hidden/${o.id}', true);
                                searchIndex = null;
                                refresh();
                              }
                              if (action == 'block') {
                                node.block(o.author, true);
                                searchIndex = null;
                                refresh();
                              }
                              if (action == 'moderate') {
                                act(() async {
                                  await node.publish('forum_hide', {
                                    'object': o.id,
                                  }, space: o.space);
                                });
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'hide',
                                child: Text('Hide for me'),
                              ),
                              if (o.author != node.person)
                                const PopupMenuItem(
                                  value: 'block',
                                  child: Text('Block author'),
                                ),
                              if (ownsForum(o.space))
                                const PopupMenuItem(
                                  value: 'moderate',
                                  child: Text('Remove from forum'),
                                ),
                            ],
                          ),
                        IconButton(
                          tooltip: 'Inspect provenance',
                          onPressed: () => provenance(context, o),
                          icon: const Icon(Icons.verified_outlined, size: 20),
                        ),
                      ],
                    ),
                    if (o.kind == 'post' && p['title'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          p['title'],
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    if (isImagePayload(p))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: InlineImage(
                          key: ValueKey(o.id),
                          files: files,
                          object: o,
                          payload: p,
                          online: network.running,
                        ),
                      ),
                    if (p['parent'] != null)
                      Text(
                        'Reply to ${short(p['parent'])}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if ((p['text'] ?? '').toString().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: SelectableText(p['text']),
                      ),
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
                    if (o.kind == 'post' && selectedThread == null)
                      TextButton.icon(
                        onPressed: () => update(() {
                          selectedThread = o.id;
                          replyTo = null;
                        }),
                        icon: const Icon(Icons.forum_outlined),
                        label: Text(
                          'Open discussion · ${replyCounts()[o.id] ?? 0} direct replies',
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (o.kind == 'post')
                          TextButton.icon(
                            onPressed: () => update(() {
                              selectedThread ??= o.id;
                              replyTo = o.id;
                            }),
                            icon: const Icon(Icons.reply, size: 16),
                            label: const Text('Reply'),
                          ),
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
                          o.isPublic ? 'Public' : 'Encrypted · selected people',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

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
    final isMessage = tab == 2;
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
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: InteractiveViewer(
                child: Image.memory(
                  image,
                  cacheWidth: 1600,
                  errorBuilder: (_, _, _) => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('This file could not be decoded as an image.'),
                  ),
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
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
        onChanged: (v) => node.subscribe('files', v),
      ),
      Expanded(child: objectList(context, publicFileObjects())),
    ],
  );
}
