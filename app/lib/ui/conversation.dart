part of 'app.dart';

/// Chat-style rendering for private conversations: bubbles, day separators
/// and compact delivery ticks. Objects are newest first; the list is reversed
/// so offset 0 is the latest message at the bottom.
extension _ConversationPages on _OurNetAppState {
  Widget conversationAvatar(String person, {double radius = 18}) {
    final label = name(person).trim();
    return CircleAvatar(
      radius: radius,
      child: Text(label.isEmpty ? '?' : label.substring(0, 1).toUpperCase()),
    );
  }

  Widget conversationList(
    BuildContext context,
    List<SignedObject> objects, {
    required ScrollController controller,
  }) {
    objects = objects.where(contentVisible).toList();
    if (objects.isEmpty) {
      return empty(
        'No messages yet',
        'Say hello — messages are end-to-end encrypted.',
        Icons.lock_outline,
      );
    }
    return ListView.builder(
      controller: controller,
      reverse: true,
      key: PageStorageKey('conversation/$contact'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: objects.length,
      itemBuilder: (context, index) {
        final o = objects[index];
        final older = index + 1 < objects.length ? objects[index + 1] : null;
        final day = messageDay(o);
        final newDay = older == null || messageDay(older) != day;
        final groupStart = newDay || older.author != o.author;
        return Column(
          children: [
            if (newDay) daySeparator(context, day),
            messageBubble(context, o, groupStart: groupStart),
          ],
        );
      },
    );
  }

  DateTime messageDay(SignedObject o) {
    final t = DateTime.fromMillisecondsSinceEpoch(o.created).toLocal();
    return DateTime(t.year, t.month, t.day);
  }

  Widget daySeparator(BuildContext context, DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final gap = today.difference(day).inDays;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    const weekdays = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', //
      'Friday', 'Saturday', 'Sunday',
    ];
    final label = gap == 0
        ? 'Today'
        : gap == 1
        ? 'Yesterday'
        : gap < 7 && gap > 0
        ? weekdays[day.weekday - 1]
        : '${day.day} ${months[day.month - 1]}'
              '${day.year == now.year ? '' : ' ${day.year}'}';
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text(label, style: Theme.of(context).textTheme.labelMedium),
          ),
        ),
      ),
    );
  }

  /// Compact tick for an outgoing message; the full wording is the tooltip.
  Widget deliveryTick(BuildContext context, SignedObject o, Json p) {
    final scheme = Theme.of(context).colorScheme;
    final detail = delivery(o, attachment: p['chunks'] is List);
    final read = node.store.setting('readBy/${o.id}') != null;
    final delivered =
        read || detail.startsWith('Delivered') || detail.startsWith('Shared');
    final forwarded =
        detail.startsWith('Stored') || detail.startsWith('Attachment details');
    return Tooltip(
      message: detail,
      child: Icon(
        delivered || forwarded ? Icons.done_all : Icons.done,
        size: 16,
        color: read
            ? Colors.lightBlue
            : forwarded
            ? scheme.outline.withValues(alpha: 0.6)
            : scheme.onSurfaceVariant,
      ),
    );
  }

  Widget messageBubble(
    BuildContext context,
    SignedObject o, {
    required bool groupStart,
  }) {
    final mine = o.author == node.person;
    final unread = !mine && node.store.setting('read/${o.id}') != true;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final time = DateTime.fromMillisecondsSinceEpoch(o.created).toLocal();
    final clock =
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    const round = Radius.circular(16);
    const tail = Radius.circular(4);
    return FutureBuilder<Json?>(
      future: node.content(o),
      builder: (context, snapshot) {
        final p = snapshot.data;
        if (p == null) return const SizedBox.shrink();
        final body = (p['text'] ?? '').toString();
        final meta = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              clock,
              style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (mine) ...[
              const SizedBox(width: 3),
              deliveryTick(context, o, p),
            ],
          ],
        );
        final bubble = Container(
          constraints: const BoxConstraints(minWidth: 72),
          decoration: BoxDecoration(
            color: mine
                ? scheme.primaryContainer
                : unread
                ? scheme.secondaryContainer
                : scheme.surface,
            borderRadius: BorderRadius.only(
              topLeft: !mine && groupStart ? tail : round,
              topRight: mine && groupStart ? tail : round,
              bottomLeft: round,
              bottomRight: round,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 1,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isImagePayload(p))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4, top: 2),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: InlineImage(
                      key: ValueKey(o.id),
                      files: files,
                      object: o,
                      payload: p,
                      online: network.running,
                    ),
                  ),
                ),
              if (p['audio'] case final Map<String, dynamic> audio
                  when p['chunks'] != null)
                voiceClip(context, o, p, audio)
              else if (p['chunks'] != null && !isImagePayload(p))
                attachmentChip(context, o, p),
              if (p['chunks'] != null && isImagePayload(p))
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: fileProgress.containsKey(o.id)
                      ? null
                      : () => saveFile(context, o, p),
                  icon: const Icon(Icons.download, size: 16),
                  label: Text(
                    fileProgress.containsKey(o.id)
                        ? 'Preparing ${(fileProgress[o.id]! * 100).round()}%'
                        : 'Save original',
                  ),
                ),
              if (fileErrors[o.id] case final error?)
                Text(
                  '$error · Verified chunks are kept for retry.',
                  style: text.bodySmall?.copyWith(color: scheme.error),
                ),
              // Time sits in the text's last line when it fits, like
              // WhatsApp: trailing spacer reserves room, then overlay.
              // Like WhatsApp: the time shares the last line when it fits,
              // otherwise it wraps below, right-aligned.
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 8,
                children: [
                  if (body.isNotEmpty) Text(body, style: text.bodyLarge),
                  Padding(padding: const EdgeInsets.only(top: 4), child: meta),
                ],
              ),
            ],
          ),
        );
        return Padding(
          padding: EdgeInsets.only(top: groupStart ? 6 : 2),
          child: Row(
            mainAxisAlignment: mine
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: [
              Flexible(
                child: LayoutBuilder(
                  builder: (context, constraints) => Align(
                    alignment: mine
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: (constraints.maxWidth * 0.8).clamp(120, 560),
                      ),
                      child: GestureDetector(
                        onTap: unread
                            ? () => act(() => node.markRead(o.id))
                            : null,
                        onLongPressStart: (d) =>
                            messageMenu(context, o, body, d.globalPosition),
                        onSecondaryTapUp: (d) =>
                            messageMenu(context, o, body, d.globalPosition),
                        child: bubble,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// A voice message: the notes player with its transcript beneath.
  Widget voiceClip(BuildContext context, SignedObject o, Json p, Json audio) {
    final transcript = (p['transcript'] as String? ?? '').trim();
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: SizedBox(
        width: 320,
        child: AudioClip(
          key: ValueKey('voice/${o.id}'),
          files: files,
          object: o,
          payload: p,
          meta: audio,
          editable: false,
          transcript: Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: transcript.isEmpty
                ? Text(
                    'No transcript',
                    style: style?.copyWith(fontStyle: FontStyle.italic),
                  )
                : SelectableText(transcript, style: style),
          ),
        ),
      ),
    );
  }

  Widget attachmentChip(BuildContext context, SignedObject o, Json p) {
    final scheme = Theme.of(context).colorScheme;
    final progress = fileProgress[o.id];
    final size = (p['size'] as num?)?.toInt() ?? 0;
    final readable = size >= 1 << 20
        ? '${(size / (1 << 20)).toStringAsFixed(1)} MB'
        : size >= 1 << 10
        ? '${(size / (1 << 10)).toStringAsFixed(0)} KB'
        : '$size bytes';
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: Material(
        color: scheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: progress != null ? null : () => saveFile(context, o, p),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.insert_drive_file_outlined),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${p['name']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        progress != null
                            ? 'Preparing ${(progress * 100).round()}%'
                            : fileErrors.containsKey(o.id)
                            ? 'Tap to retry download'
                            : readable,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                progress != null
                    ? SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value: progress,
                        ),
                      )
                    : const Icon(Icons.download, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> messageMenu(
    BuildContext context,
    SignedObject o,
    String body,
    Offset at,
  ) async {
    final mine = o.author == node.person;
    final read = node.store.setting('read/${o.id}') == true;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (body.isNotEmpty)
          const PopupMenuItem(value: 'copy', child: Text('Copy text')),
        if (!mine && !read)
          const PopupMenuItem(value: 'read', child: Text('Mark read')),
        const PopupMenuItem(value: 'info', child: Text('Message info')),
      ],
    );
    if (!context.mounted) return;
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: body));
        notice('Copied');
      case 'read':
        act(() => node.markRead(o.id));
      case 'info':
        await provenance(context, o);
    }
  }
}

/// Faint staggered dot pattern behind a conversation.
class ChatWallpaper extends CustomPainter {
  final Color color;
  const ChatWallpaper(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const step = 22.0;
    var row = 0;
    for (var y = step / 2; y < size.height; y += step, row++) {
      for (var x = row.isEven ? step / 2 : step; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), 1.4, paint);
      }
    }
  }

  @override
  bool shouldRepaint(ChatWallpaper old) => old.color != color;
}
