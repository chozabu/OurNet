part of 'app.dart';

extension _ForumFeatures on _OurNetAppState {
  /// Latest owner-signed definition per forum, computed once per build.
  Json? forumInfo(String id) => memo('forums', () {
    final latest = <String, SignedObject>{};
    for (final o in node.store.objects(kind: 'forum', limit: Node.maxObjects)) {
      if (!o.isPublic ||
          !o.space.startsWith('forum2:${o.author}:') ||
          !node.visible(o)) {
        continue;
      }
      final old = latest[o.space];
      final order = old == null ? 1 : o.created.compareTo(old.created);
      if (order > 0 || order == 0 && o.id.compareTo(old!.id) > 0) {
        latest[o.space] = o;
      }
    }
    return {
      for (final entry in latest.entries)
        entry.key: entry.value.data['payload'] as Json,
    };
  })[id];

  String forumName(String id) => forumInfo(id)?['name'] as String? ?? id;
  bool ownsForum(String id) => id.startsWith('forum2:${node.person}:');
  bool contentVisible(SignedObject o) {
    if (!node.visible(o) ||
        memo(
          'hidden',
          () => node.store.trueSettings('hidden/'),
        ).contains(o.id)) {
      return false;
    }
    if (o.kind != 'post') return true;
    // Posts removed by their forum's owner, keyed by space and object.
    return !memo(
      'moderated',
      () => {
        for (final m in node.store.objects(
          kind: 'forum_hide',
          limit: Node.maxObjects,
        ))
          if (m.isPublic && m.space.startsWith('forum2:${m.author}:'))
            '${m.space}/${m.data['payload']['object']}',
      },
    ).contains('${o.space}/${o.id}');
  }

  Future<void> forumSettings(BuildContext context) async {
    final description = await ask(
      context,
      'Forum description',
      initial: forumInfo(space)?['description'] ?? '',
      lines: 3,
    );
    if (description == null) return;
    await node.publish('forum', {
      'name': forumName(space),
      'description': description,
    }, space: space);
  }

  Future<void> newDiscussion(BuildContext context) async {
    final title = TextEditingController(), body = TextEditingController();
    dynamic attachment;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: const Text('New discussion'),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: title,
                    autofocus: true,
                    maxLength: 200,
                    decoration: const InputDecoration(
                      labelText: 'Discussion title',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: body,
                    minLines: 3,
                    maxLines: 7,
                    decoration: const InputDecoration(
                      labelText: 'What would you like to discuss?',
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await FilePicker.pickFile();
                      if (context.mounted && picked != null) {
                        change(() => attachment = picked);
                      }
                    },
                    icon: const Icon(Icons.image_outlined),
                    label: Text(
                      attachment == null
                          ? 'Add image or file'
                          : attachment.name as String,
                    ),
                  ),
                  if (attachment != null)
                    TextButton(
                      onPressed: () => change(() => attachment = null),
                      child: const Text('Remove attachment'),
                    ),
                  const Text(
                    'Public · anyone receiving this forum can read this discussion.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (title.text.trim().isNotEmpty) Navigator.pop(context, true);
              },
              child: const Text('Publish discussion'),
            ),
          ],
        ),
      ),
    );
    final heading = title.text.trim(), text = body.text.trim();
    Future<void>.delayed(const Duration(seconds: 1), () {
      title.dispose();
      body.dispose();
    });
    if (accepted != true) return;
    if (attachment == null) {
      await node.publish('post', {
        'title': heading,
        'text': text,
        'parent': null,
      }, space: space);
    } else {
      final directory = await getTemporaryDirectory();
      final temp = File('${directory.path}/${randomId()}.post');
      try {
        final stream = attachment.readAsByteStream() as Stream<List<int>>;
        final output = temp.openWrite();
        var size = 0;
        try {
          await for (final chunk in stream) {
            size += chunk.length;
            if (size > Files.maxSize) throw StateError('File exceeds 64 MiB');
            output.add(chunk);
          }
        } finally {
          await output.close();
        }
        await files.publish(
          temp.path,
          name: attachment.name as String,
          postSpace: space,
          post: {'title': heading, 'text': text, 'parent': null},
        );
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    }
    update(() {
      selectedThread = null;
      replyTo = null;
    });
  }
}
