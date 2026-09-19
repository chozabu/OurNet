import 'dart:async';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:workmanager/workmanager.dart';
import 'network.dart';
import 'notifications.dart';
import 'session.dart';

/// Work done while the app is in the background on Android: a periodic sync
/// (WorkManager), a short stay online after sending (`linger`), and the
/// buttons on chat notifications.
///
/// Two friends' phones rarely have the app open at the same moment. A short
/// periodic exchange lets either side collect what the other queued, and
/// answers peers that are retrying at the time.
///
/// WorkManager and notification buttons run their callbacks in other
/// isolates, usually inside the app's own process, where
/// the profile's file lock does not exclude them (POSIX locks are per
/// process). The profile is therefore owned by whichever isolate holds
/// [_owner] in the [IsolateNameServer]. Work is handed to a live owner as a
/// command: `sync`, `linger`, or a notification action such as `reply`. With no owner, the isolate opens the profile itself. The
/// app asks such a run to `yield` before it opens the profile.
@visibleForTesting
const profileOwner = 'ournet-profile-owner';
const _owner = profileOwner;
const _task = 'ournet-background-sync';
const _lingerTask = 'ournet-linger';

/// Commands that only ask for a sync.
const _syncing = {'sync', 'linger'};

/// How long a background run keeps answering peers after its own exchange.
const _linger = Duration(seconds: 10);

/// Run by the app isolate after it takes over background work, with the
/// command's name. Null until the app can sync (for example during setup),
/// in which case nothing is sent.
Future<void> Function(String command)? onBackgroundSync;

final _opened = Completer<Node>();

/// Whether this isolate is the profile owner, see [claimProfile].
bool ownsProfile = false;

/// The profile the app opened after [claimProfile]. Notification actions
/// handed to the app are carried out on it.
void profileOpened(Node node) {
  if (!_opened.isCompleted) _opened.complete(node);
}

/// A command sent to the owner: `[name, reply port, ...arguments]`.
(List<String>, SendPort)? _command(Object? message) {
  if (message is! List || message.length < 2 || message[1] is! SendPort) {
    return null;
  }
  final parts = [message[0], ...message.skip(2)];
  if (parts.any((p) => p is! String)) return null;
  return (parts.cast<String>(), message[1] as SendPort);
}

/// Registers this (app) isolate as the profile owner, asking a background run
/// to stop first. Call before opening the profile, then [profileOpened].
Future<void> claimProfile() async {
  final port = ReceivePort();
  while (!IsolateNameServer.registerPortWithName(port.sendPort, _owner)) {
    final owner = IsolateNameServer.lookupPortByName(_owner);
    // Ownership may have been released between the two calls.
    if (owner == null) continue;
    // A background run stops its network and closes the profile promptly.
    // An owner that never answers has gone, for example an engine that was
    // destroyed without removing its mapping.
    if (await _ask(owner, const ['yield'], const Duration(seconds: 30)) !=
        true) {
      _release(owner);
    }
  }
  ownsProfile = true;
  port.listen((message) async {
    final command = _command(message);
    if (command == null) return;
    final (action, reply) = command;
    reply.send('ack');
    try {
      // The app never gives up the profile it holds.
      if (action.first != 'yield') {
        if (!_syncing.contains(action.first)) {
          await _perform(
            await _opened.future.timeout(const Duration(minutes: 1)),
            action,
          );
        }
        await onBackgroundSync?.call(action.first);
      }
    } catch (e) {
      debugPrint('Background ${action.first} failed: $e');
    }
    reply.send('done');
  });
}

/// Carries out what [action] asks of an open profile, beyond syncing.
Future<void> _perform(Node node, List<String> action) async {
  switch (action) {
    case [final command] when _syncing.contains(command):
      break;
    default:
      await runNotificationAction(node, action);
  }
}

/// Carries out [command] as, or through, the profile owner.
Future<void> runBackgroundCommand(List<String> command) async {
  DartPluginRegistrant.ensureInitialized();
  try {
    await _run(command);
  } catch (e) {
    debugPrint('Background ${command.first} failed: $e');
  }
}

/// Removes [_owner] only while it still names [port].
void _release(SendPort port) {
  if (IsolateNameServer.lookupPortByName(_owner) == port) {
    IsolateNameServer.removePortNameMapping(_owner);
  }
}

/// Sends [command] to [owner]. True once it finishes, false if it was
/// acknowledged but did not finish within [timeout], and null if the owner
/// did not acknowledge at all.
Future<bool?> _ask(
  SendPort owner,
  List<String> command,
  Duration timeout,
) async {
  final reply = ReceivePort();
  final messages = StreamIterator(reply);
  try {
    owner.send([command.first, reply.sendPort, ...command.skip(1)]);
    final acknowledged = await messages.moveNext().timeout(
      const Duration(seconds: 2),
      onTimeout: () => false,
    );
    if (!acknowledged) return null;
    return await messages.moveNext().timeout(timeout, onTimeout: () => false);
  } finally {
    await messages.cancel();
    reply.close();
  }
}

Future<Workmanager> _workmanager() async {
  final manager = Workmanager();
  await manager.initialize(backgroundSyncDispatcher);
  return manager;
}

/// Asks Android to keep the app running briefly while it stays online for
/// messages that have not been delivered yet. Android only.
Future<void> scheduleLinger() async {
  await (await _workmanager()).registerOneOffTask(
    _lingerTask,
    _lingerTask,
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.replace,
  );
}

/// Schedules or cancels the periodic task. Android only.
Future<void> scheduleBackgroundSync({required bool enabled}) async {
  final manager = await _workmanager();
  if (!enabled) {
    await manager.cancelByUniqueName(_task);
    return;
  }
  await manager.registerPeriodicTask(
    _task,
    _task,
    // WorkManager's minimum period.
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}

@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, input) async {
    // Failure is retried by the next period, not by WorkManager backoff.
    await runBackgroundCommand([task == _lingerTask ? 'linger' : 'sync']);
    return true;
  });
}

/// Reply and mark-read buttons on chat notifications. Android runs this in
/// its own isolate, whether or not the app is running.
@pragma('vm:entry-point')
void notificationActionDispatcher(NotificationResponse response) {
  final action = notificationAction(response);
  if (action != null) unawaited(runBackgroundCommand(action));
}

Future<void> _run(List<String> command) async {
  while (true) {
    final existing = IsolateNameServer.lookupPortByName(_owner);
    if (existing != null) {
      // A live owner, even a slow one, keeps the profile.
      if (await _ask(existing, command, const Duration(minutes: 5)) != null) {
        return;
      }
      _release(existing);
    }
    final port = ReceivePort();
    if (IsolateNameServer.registerPortWithName(port.sendPort, _owner)) {
      return _own(port, command);
    }
    // Another run became the owner first; hand the command to it instead.
    port.close();
  }
}

Future<void> _own(ReceivePort port, List<String> command) async {
  final run = _HeadlessRun(command);
  final finished = Completer<void>();
  port.listen((message) {
    final request = _command(message);
    if (request == null) return;
    final (action, reply) = request;
    reply.send('ack');
    switch (action.first) {
      case 'yield':
        run.stop();
        unawaited(finished.future.then((_) => reply.send('done')));
      case final command when _syncing.contains(command):
        // Already syncing.
        reply.send('done');
      default:
        run.perform(action, reply);
    }
  });
  try {
    // The run stops early on a yield, but always closes the profile first.
    await run.sync();
  } finally {
    // Release ownership only after the profile is closed.
    _release(port.sendPort);
    finished.complete();
    port.close();
  }
  // Actions that arrived as the profile was closing go to the next owner.
  for (final (action, reply) in run.late) {
    unawaited(
      runBackgroundCommand(action).whenComplete(() => reply.send('done')),
    );
  }
}

/// A profile opened without the app. It syncs, and carries out notification
/// actions handed to it meanwhile, one at a time.
class _HeadlessRun {
  final List<String> command;
  final _yielded = Completer<void>();
  Node? _node;
  Network? _network;
  bool _closing = false;
  Future<void> _actions = Future.value();
  final late = <(List<String>, SendPort)>[];

  _HeadlessRun(this.command);

  void stop() {
    if (!_yielded.isCompleted) _yielded.complete();
  }

  void perform(List<String> action, SendPort reply) {
    final node = _node;
    if (node == null || _closing) {
      late.add((action, reply));
      return;
    }
    _actions = _actions.then((_) async {
      try {
        await _perform(node, action);
        await _network?.syncAll();
      } catch (e) {
        debugPrint('Background ${action.first} failed: $e');
      }
      reply.send('done');
    });
  }

  Future<void> sync() async {
    final Node node;
    try {
      node = await openNode();
    } catch (_) {
      _closing = true;
      await closeProfile();
      rethrow;
    }
    Notifications? notifications;
    try {
      if (needsSetup) return;
      notifications = Notifications(
        node,
        onAction: notificationActionDispatcher,
      );
      await notifications.initialise();
      await _perform(node, command);
      _node = node;
      if (node.store.setting('autoConnect') == false ||
          (command.first == 'sync' &&
              node.store.setting('backgroundSync') == false)) {
        return;
      }
      final network = _network = Network(node);
      await network.start(automatic: false);
      await Future.any([
        () async {
          await network.syncAll();
          await Future<void>.delayed(_linger);
        }(),
        _yielded.future,
      ]);
    } finally {
      _closing = true;
      await _actions;
      await _network?.stop();
      await notifications?.close();
      await node.close();
      await closeProfile();
    }
  }
}
