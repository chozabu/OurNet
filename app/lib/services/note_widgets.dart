import 'dart:async';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';
import 'coalesced_task.dart';
import 'session.dart';

/// Android persists a bounded snapshot/outbox; only core publishes encrypted
/// operations. A checkbox action carries observed parents and membership epoch.
class NoteWidgets {
  final Notes notes;
  final Future<void> Function(String?, bool) open;
  final void Function(String) notice;
  final MethodChannel channel;
  late final CoalescedTask task;
  StreamSubscription<void>? _changes;
  bool _closed = false;
  String get profile =>
      '$activeProfile:${notes.node.person}:${notes.node.identity.device}';
  NoteWidgets(
    this.notes,
    this.open,
    this.notice, {
    this.channel = const MethodChannel('ournet/widgets'),
  }) {
    task = CoalescedTask(drain, (e) => notice('Widget update will retry: $e'));
  }
  Future<void> start() async {
    try {
      await channel.invokeMethod<void>('activate', {'profile': profile});
      if (_closed) return;
      channel.setMethodCallHandler((call) async {
        if (call.method == 'changed') schedule();
      });
      _changes = notes.node.changes.stream.listen((_) => schedule());
      schedule();
    } catch (e) {
      notice('Widgets unavailable: $e');
    }
  }

  void schedule() => task.schedule();
  Future<void> drain() async {
    final state = await channel.invokeMapMethod<String, dynamic>('state');
    if (_closed || state == null) return;
    for (final raw in (state['pending'] as List? ?? []).take(128)) {
      final op = Map<String, dynamic>.from(raw);
      if (op['profile'] != profile || op['error'] != null) continue;
      try {
        await notes.edit(
          op['note'],
          op['epoch'],
          op['field'],
          op['value'],
          (op['parents'] as List).cast<String>(),
          request: op['id'],
        );
        await channel.invokeMethod<void>('ack', {'id': op['id']});
      } catch (e) {
        // Keep rejected offline work in the encrypted native outbox. Do not
        // reinterpret an old-epoch edit as permission to write to a new group.
        await channel.invokeMethod<void>('failed', {
          'id': op['id'],
          'error': 'This note changed or is unavailable. Open it to review.',
        });
        notice('A saved widget change needs review. Open the widget settings.');
      }
    }
    final catalog = await notes.summaries();
    final snapshots = <Map<String, dynamic>>[];
    for (final raw in (state['configs'] as List? ?? []).take(16)) {
      final config = Map<String, dynamic>.from(raw);
      final note = config['profile'] == profile
          ? await notes.get(config['note'])
          : null;
      final available = note != null && !note.deleted;
      final show = config['show'] == true;
      snapshots.add({
        'widget': config['widget'],
        'note': config['note'],
        'profile': config['profile'],
        'available': available,
        'show': show,
        if (available) ...{
          'epoch': note.epoch,
          'title': show
              ? note.title.substring(0, note.title.length.clamp(0, 100))
              : 'OurNet note',
          'text': show
              ? note.text.substring(0, note.text.length.clamp(0, 2000))
              : '',
          'shared': note.members.length > 1,
          'more': note.checks.length > 20 || note.text.length > 2000,
          'checks': show
              ? [
                  for (final id in note.checks.take(20))
                    {
                      'id': id,
                      'text': (note.value('check:$id:text') as String)
                          .substring(
                            0,
                            (note.value('check:$id:text') as String).length
                                .clamp(0, 160),
                          ),
                      'done': note.value('check:$id:done') == true,
                      'parents': note.parents('check:$id:done'),
                    },
                ]
              : [],
        },
      });
    }
    if (_closed) return;
    await channel.invokeMethod<void>('publish', {
      'profile': profile,
      'catalog': [
        for (final n in catalog.take(200))
          {'id': n.data['entry'], 'title': n.data['title']},
      ],
      'snapshots': snapshots,
    });
    final launch = state['launch'];
    if (launch is Map && launch['profile'] == profile) {
      // Claim before navigation to avoid duplicate routes on activity recreation.
      await channel.invokeMethod<void>('claim', {'id': launch['id']});
      unawaited(
        open(launch['note'], launch['checklist'] == true).catchError((
          Object e,
        ) {
          notice('Could not open the note: $e');
        }),
      );
    }
  }

  void close() {
    _closed = true;
    _changes?.cancel();
    task.close();
    channel.setMethodCallHandler(null);
  }
}
