import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';

import 'message_text.dart';

/// What a wall page needs from the app around it.
class WallContext {
  final Node node;
  final String Function(String person) nameOf;
  final Widget Function(String person, double radius) avatar;
  final void Function(String message) notice;

  /// Opens a person's own wall.
  final void Function(String person) openWall;
  const WallContext({
    required this.node,
    required this.nameOf,
    required this.avatar,
    required this.notice,
    required this.openWall,
  });
}

/// Posts on one wall ([Wall]) or every followed one ([WallFeed]), newest
/// first, with a composer for this person's own wall above them. See
/// docs/WALL.md.
class WallPage extends StatefulWidget {
  final WallContext wall;
  final WallView view;

  /// Shows only friends-only posts (personal) or public ones; null for all.
  final ScopeKind? scope;
  final bool composer;
  final Widget? header;
  const WallPage({
    super.key,
    required this.wall,
    required this.view,
    this.scope,
    this.composer = true,
    this.header,
  });

  @override
  State<WallPage> createState() => _WallPageState();
}

class _WallPageState extends State<WallPage> {
  Node get node => widget.wall.node;
  WallView get view => widget.view;
  StreamSubscription<Set<String>>? _changes;
  final _composer = TextEditingController();
  var _audience = WallAudience.friends;
  bool _posting = false, _loadingMore = false;
  bool _refreshing = false, _again = false;
  late final _votes = ForumVotes(node);

  @override
  void initState() {
    super.initState();
    _subscribe();
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(WallPage old) {
    super.didUpdateWidget(old);
    if (old.view != view) unawaited(_refresh());
  }

  void _subscribe() {
    _changes = node.onChangesTo({
      ...Walls.kinds,
      ForumVotes.kind,
    }, () => unawaited(_refresh()));
  }

  /// Takes in what arrived, once at a time; a change meanwhile runs again.
  Future<void> _refresh() async {
    if (_refreshing) {
      _again = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _again = false;
        await view.refresh();
        await _votes.catchUp();
      } while (_again);
    } catch (e) {
      widget.wall.notice('Could not read posts: $e');
    } finally {
      _refreshing = false;
    }
    if (!mounted) return;
    setState(() {});
    if (view.unseen() > 0) view.markSeen();
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    _composer.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    setState(() => _posting = true);
    try {
      await view.publish(text, audience: _audience);
      _composer.clear();
      await _refresh();
    } catch (e) {
      widget.wall.notice('Could not post: ${_reason(e)}');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _more() async {
    setState(() => _loadingMore = true);
    try {
      await view.more();
    } catch (e) {
      widget.wall.notice('Could not load earlier posts: ${_reason(e)}');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  List<WallPost> get _shown => [
    for (final p in view.posts)
      if (switch (widget.scope) {
        ScopeKind.personal => !p.isPublic,
        ScopeKind.public => p.isPublic,
        _ => true,
      })
        p,
  ];

  @override
  Widget build(BuildContext context) {
    final posts = _shown;
    return ListView.builder(
      itemCount: posts.length + 3,
      itemBuilder: (context, index) {
        if (index == 0) return widget.header ?? const SizedBox.shrink();
        if (index == 1) {
          return widget.composer
              ? _composerCard(context)
              : const SizedBox.shrink();
        }
        if (index == posts.length + 2) return _footer(context, posts.isEmpty);
        final post = posts[index - 2];
        return WallPostCard(
          key: ValueKey(post.id),
          wall: widget.wall,
          view: view,
          post: post,
          votes: _votes,
          changed: () => unawaited(_refresh()),
        );
      },
    );
  }

  Widget _composerCard(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _composer,
            minLines: 2,
            maxLines: 8,
            maxLength: Walls.maxText,
            buildCounter:
                (_, {required currentLength, required isFocused, maxLength}) =>
                    null,
            decoration: const InputDecoration(
              hintText: 'What is new?',
              border: InputBorder.none,
            ),
          ),
          Row(
            children: [
              Flexible(
                child: SegmentedButton<WallAudience>(
                  segments: const [
                    ButtonSegment(
                      value: WallAudience.friends,
                      icon: Icon(Icons.people_outline),
                      label: Text('Friends'),
                    ),
                    ButtonSegment(
                      value: WallAudience.public,
                      icon: Icon(Icons.public),
                      label: Text('Public'),
                    ),
                  ],
                  selected: {_audience},
                  onSelectionChanged: (s) =>
                      setState(() => _audience = s.first),
                ),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _posting ? null : _post,
                child: _posting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Post'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _footer(BuildContext context, bool empty) {
    if (!view.loaded) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (empty && view.exhausted) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'No posts yet. Friends\' posts show here, and your own; '
          'friends-only posts are for the friends you have when you post.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    if (view.exhausted) return const SizedBox(height: 24);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: _loadingMore
            ? const CircularProgressIndicator()
            : OutlinedButton(
                onPressed: _more,
                child: const Text('Show earlier'),
              ),
      ),
    );
  }
}

String _reason(Object e) => e is StateError ? e.message : '$e';

/// When [at] was, briefly: "5 min", "3 h", or a date.
String wallTime(BuildContext context, int at) {
  final then = DateTime.fromMillisecondsSinceEpoch(at);
  final ago = DateTime.now().difference(then);
  if (ago.inMinutes < 1) return 'just now';
  if (ago.inHours < 1) return '${ago.inMinutes} min';
  if (ago.inDays < 1) return '${ago.inHours} h';
  return MaterialLocalizations.of(context).formatMediumDate(then);
}

/// One post: who, when and for whom, what it says (and reshares), its
/// comments collapsed to the last two, and what can be done with it.
class WallPostCard extends StatefulWidget {
  final WallContext wall;
  final WallView view;
  final WallPost post;
  final ForumVotes votes;
  final VoidCallback changed;
  const WallPostCard({
    super.key,
    required this.wall,
    required this.view,
    required this.post,
    required this.votes,
    required this.changed,
  });

  @override
  State<WallPostCard> createState() => _WallPostCardState();
}

class _WallPostCardState extends State<WallPostCard> {
  bool _allComments = false, _commenting = false, _sending = false;
  WallComment? _replyTo;
  final _comment = TextEditingController();

  WallContext get wall => widget.wall;
  WallPost get post => widget.post;
  Node get node => wall.node;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _comment.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await widget.view.comment(post, text, parent: _replyTo?.id);
      _comment.clear();
      setState(() {
        _replyTo = null;
        _allComments = true;
      });
      widget.changed();
    } catch (e) {
      wall.notice('Could not comment: ${_reason(e)}');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _hide(SignedObject object, {required bool isPost}) async {
    try {
      await widget.view.hide(object);
      widget.changed();
    } catch (e) {
      wall.notice('Could not ${isPost ? 'delete' : 'hide'}: ${_reason(e)}');
    }
  }

  Future<void> _reshare(BuildContext context) async {
    final text = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Share on your wall'),
        content: TextField(
          controller: text,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: 'Say something about it (optional)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Share publicly'),
          ),
        ],
      ),
    );
    final words = text.text;
    text.dispose();
    if (go != true) return;
    try {
      await widget.view.reshare(post.object, words);
      wall.notice('Shared on your wall');
      widget.changed();
    } catch (e) {
      wall.notice('Could not share: ${_reason(e)}');
    }
  }

  Future<void> _like(bool liked) async {
    try {
      await widget.votes.vote(
        post.object,
        post.object.data['payload'] as Json,
        liked ? 0 : 1,
      );
      setState(() {});
    } catch (e) {
      wall.notice('Could not like: ${_reason(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final mine = post.owner == node.person;
    final comments = post.comments;
    final shown = _allComments || comments.length <= 2
        ? comments
        : comments.sublist(comments.length - 2);
    final likes = post.isPublic
        ? widget.votes.votes(post.id, space: post.object.space, public: true)
        : const <String, int>{};
    final likers = [
      for (final MapEntry(:key, :value) in likes.entries)
        if (value > 0) key,
    ];
    final liked = likes[node.person] == 1;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                InkWell(
                  onTap: () => wall.openWall(post.owner),
                  borderRadius: BorderRadius.circular(20),
                  child: wall.avatar(post.owner, 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        onTap: () => wall.openWall(post.owner),
                        child: Text(
                          mine ? 'You' : wall.nameOf(post.owner),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Row(
                        children: [
                          Text(
                            wallTime(context, post.created),
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(width: 4),
                          Tooltip(
                            message: post.isPublic
                                ? 'Public'
                                : 'Friends of ${mine ? 'yours' : wall.nameOf(post.owner)}',
                            child: Icon(
                              post.isPublic
                                  ? Icons.public
                                  : Icons.people_outline,
                              size: 14,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: (choice) {
                    switch (choice) {
                      case 'link':
                        unawaited(
                          Clipboard.setData(
                            ClipboardData(
                              text: Links.wall(post.owner, post: post.id),
                            ),
                          ),
                        );
                        wall.notice(
                          post.isPublic
                              ? 'Link copied'
                              : 'Link copied: it opens for their friends only',
                        );
                      case 'delete':
                        unawaited(_hide(post.object, isPost: true));
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'link',
                      child: Text('Copy link'),
                    ),
                    if (mine)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete post'),
                      ),
                  ],
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 8, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (post.title case final title?)
                    Text(title, style: theme.textTheme.titleMedium),
                  if (post.text.isNotEmpty) MessageText(post.text),
                  if (post.shared case final shared?)
                    _sharedCard(context, shared, post.sharedPayload!),
                ],
              ),
            ),
            Row(
              children: [
                if (post.isPublic)
                  TextButton.icon(
                    onPressed: () => unawaited(_like(liked)),
                    icon: Icon(
                      liked ? Icons.favorite : Icons.favorite_border,
                      size: 18,
                    ),
                    label: Text(likers.isEmpty ? 'Like' : '${likers.length}'),
                  ),
                TextButton.icon(
                  onPressed: () => setState(() => _commenting = !_commenting),
                  icon: const Icon(Icons.mode_comment_outlined, size: 18),
                  label: Text(
                    comments.isEmpty ? 'Comment' : '${comments.length}',
                  ),
                ),
                // Only public posts travel further.
                if (post.isPublic)
                  TextButton.icon(
                    onPressed: () => unawaited(_reshare(context)),
                    icon: const Icon(Icons.repeat, size: 18),
                    label: const Text('Share'),
                  ),
              ],
            ),
            if (comments.length > shown.length)
              TextButton(
                onPressed: () => setState(() => _allComments = true),
                child: Text('Show all ${comments.length} comments'),
              ),
            for (final c in shown) _commentRow(context, c, mine),
            if (_commenting || _replyTo != null) _commentBox(context),
          ],
        ),
      ),
    );
  }

  Widget _sharedCard(BuildContext context, SignedObject shared, Json payload) {
    final theme = Theme.of(context);
    final forum = shared.kind == 'post';
    return Card(
      margin: const EdgeInsets.only(top: 8),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                wall.avatar(shared.author, 12),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    [
                      wall.nameOf(shared.author),
                      if (forum) 'in ${shared.space}',
                      wallTime(context, shared.created),
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (payload['title'] case final String title)
              Text(title, style: theme.textTheme.titleSmall),
            if (payload['text'] case final String text when text.isNotEmpty)
              MessageText(text),
          ],
        ),
      ),
    );
  }

  Widget _commentRow(BuildContext context, WallComment c, bool myWall) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(12.0 + 16 * c.depth.clamp(0, 4), 4, 4, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => wall.openWall(c.author),
            child: wall.avatar(c.author, 12),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${c.author == node.person ? 'You' : wall.nameOf(c.author)}'
                  ' · ${wallTime(context, c.created)}',
                  style: theme.textTheme.bodySmall,
                ),
                MessageText(c.text),
                Row(
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => setState(() => _replyTo = c),
                      child: const Text('Reply'),
                    ),
                    if (myWall && c.author != node.person)
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () =>
                            unawaited(_hide(c.object, isPost: false)),
                        child: const Text('Hide'),
                      ),
                    if (myWall && c.author == node.person)
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () =>
                            unawaited(_hide(c.object, isPost: false)),
                        child: const Text('Delete'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _commentBox(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_replyTo case final reply?)
          Row(
            children: [
              Expanded(
                child: Text(
                  'Replying to ${reply.author == node.person ? 'yourself' : wall.nameOf(reply.author)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                tooltip: 'Cancel reply',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _replyTo = null),
                icon: const Icon(Icons.close, size: 16),
              ),
            ],
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _comment,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => unawaited(_send()),
                decoration: InputDecoration(
                  hintText: post.isPublic
                      ? 'Write a comment'
                      : 'Write a comment for their friends',
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Send',
              onPressed: _sending ? null : () => unawaited(_send()),
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ],
    ),
  );
}

/// One person's wall as a page of its own, with following.
class WallScreen extends StatefulWidget {
  final WallContext wall;
  final String person;
  const WallScreen({super.key, required this.wall, required this.person});

  @override
  State<WallScreen> createState() => _WallScreenState();
}

class _WallScreenState extends State<WallScreen> {
  late final view = Wall(widget.wall.node, widget.person);

  @override
  Widget build(BuildContext context) {
    final node = widget.wall.node;
    final mine = view.mine;
    final friend = node.connections.isFriend(widget.person);
    return Scaffold(
      appBar: AppBar(
        title: Text(mine ? 'Your posts' : widget.wall.nameOf(widget.person)),
        actions: [
          if (!mine)
            TextButton.icon(
              onPressed: () {
                try {
                  view.follow(!view.following);
                } catch (e) {
                  widget.wall.notice(_reason(e));
                }
                setState(() {});
              },
              icon: Icon(view.following ? Icons.check : Icons.add),
              label: Text(view.following ? 'Following' : 'Follow'),
            ),
          IconButton(
            tooltip: 'Copy link to this wall',
            onPressed: () {
              unawaited(
                Clipboard.setData(
                  ClipboardData(text: Links.wall(widget.person)),
                ),
              );
              widget.wall.notice('Link copied');
            },
            icon: const Icon(Icons.link),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: WallPage(
          wall: widget.wall,
          view: view,
          composer: mine,
          header: mine || friend
              ? null
              : Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    view.following
                        ? 'You see their public posts, as they reach you '
                              'through friends who follow this wall too.'
                        : 'Follow to receive their public posts through '
                              'friends who follow this wall.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
        ),
      ),
    );
  }
}
