part of 'app.dart';

extension _VotingPages on _OurNetAppState {
  Widget voting(BuildContext context) => ListView(
    children: [
      const Text(
        'Community votes',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      ),
      const Text(
        'Votes are public signed objects. Direct votes override delegation; cycles contribute no vote.',
      ),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
            onPressed: people.isEmpty
                ? null
                : () => act(() async {
                    final target = await choosePerson(context);
                    if (target == null || !context.mounted) return;
                    final topic = await ask(
                      context,
                      'Delegate in which community?',
                      initial: space,
                    );
                    if (topic == null || topic.isEmpty) return;
                    await node.publish('delegate', {
                      'person': target,
                    }, space: topic);
                  }),
            child: const Text('Delegate a community vote'),
          ),
          TextButton(
            onPressed: () => act(() async {
              final topic = await ask(
                context,
                'Remove delegation for community',
                initial: space,
              );
              if (topic != null) {
                await node.publish('delegate', {'person': ''}, space: topic);
              }
            }),
            child: const Text('Remove delegation'),
          ),
        ],
      ),
      ...node.store.objects(kind: 'post').where(node.visible).map((o) {
        final latest = effectiveVotes(
          o.id,
          o.space,
          memo(
            'visibleObjects',
            () => node.store.objects().where(node.visible).toList(),
          ),
        );
        final score = latest.values.fold<int>(0, (a, b) => a + b);
        return Card(
          child: ListTile(
            title: Text(
              o.data['payload']['text'] ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('${o.space} · ${name(o.author)}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Upvote',
                  onPressed: () => act(() async {
                    await node.publish('vote', {
                      'object': o.id,
                      'value': 1,
                    }, space: o.space);
                  }),
                  icon: const Icon(Icons.arrow_upward),
                ),
                Text('$score'),
                IconButton(
                  tooltip: 'Downvote',
                  onPressed: () => act(() async {
                    await node.publish('vote', {
                      'object': o.id,
                      'value': -1,
                    }, space: o.space);
                  }),
                  icon: const Icon(Icons.arrow_downward),
                ),
              ],
            ),
          ),
        );
      }),
    ],
  );
}
