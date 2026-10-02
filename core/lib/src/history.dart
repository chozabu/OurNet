import 'dart:async';

import 'drive.dart';
import 'model.dart';
import 'everyday.dart';
import 'node.dart';
import 'notes.dart';
import 'calendar.dart';

/// Hands this person's other devices everything earlier that they could not
/// read on their own: chats (by key grant), and files, inbox, groups and notes
/// (by re-issue). Returns how many chat keys were granted; [progress] is told
/// that count as it grows.
///
/// Whether a device should read what came before it is its owner's choice, so
/// callers ask first; pairing asks with "Share history" and the device list
/// offers it afterwards.
Future<int> shareAllHistory(Node node, {void Function(int)? progress}) async {
  // Each step stands alone: a failure in one must not keep chats, which are
  // the part people notice, from reaching the other device. What failed is
  // reported at the end, with where, so it can be fixed rather than guessed at.
  final failures = <String>[];
  Future<T?> step<T>(String name, Future<T> Function() run) async {
    try {
      return await run();
    } catch (e, stack) {
      final where = stack
          .toString()
          .split('\n')
          .take(3)
          .map((l) => l.trim())
          .join(' < ');
      failures.add('$name: $e${where.isEmpty ? '' : ' [$where]'}');
      return null;
    }
  }

  final granted =
      await step(
        'chats',
        () => node.shareKeys(history: true, progress: progress),
      ) ??
      0;
  await step('files', () => Drive(node).shareHistory());
  await step('inbox', () => Everyday(node).shareHistory());
  // Re-encrypted for the devices already added: without this their groups
  // and notes stay unreadable there for good, since a later edit arrives in a
  // space they have no record for.
  await step('groups', () => Everyday(node).shareRooms());
  await step('notes', () => Notes(node).shareNotes());
  await step('calendar', () {
    final notes = Notes(node);
    return Calendar(node, notes.state).shareAll();
  });
  if (failures.isEmpty) markHistoryOffered(node);
  if (failures.isNotEmpty) {
    throw StateError(
      'Shared $granted chat items, but not everything. ${failures.join('; ')}',
    );
  }
  return granted;
}

const _offered = 'historyOffered';

/// This person's other devices, not yet removed.
List<DeviceCertificate> _otherDevices(Node node) => [
  for (final c in node.contacts.values)
    if (c.person == node.person &&
        c.device != node.identity.device &&
        !node.revoked.contains(c.device))
      c,
];

/// Own devices this device has never offered its history to, when it has
/// history worth offering. A device linked by an earlier build, or one that
/// declined "Share history" while pairing, would otherwise never read chats
/// from before it and nothing would say why.
List<DeviceCertificate> devicesAwaitingHistory(Node node) {
  final others = _otherDevices(node);
  if (others.isEmpty) return const [];
  final offered = {...?(node.store.setting(_offered) as List?)?.cast<String>()};
  final waiting = [
    for (final c in others)
      if (!offered.contains(c.device)) c,
  ];
  if (waiting.isEmpty) return const [];
  // A new profile has nothing to hand over; its first device shares nothing.
  if (node.store.objects(kind: 'message', limit: 1).isEmpty) {
    markHistoryOffered(node);
    return const [];
  }
  return waiting;
}

/// Records that every current device of this person has been offered history,
/// whether or not it was taken.
void markHistoryOffered(Node node) =>
    node.store.set(_offered, [for (final c in _otherDevices(node)) c.device]);

/// What this device holds and can read, for a bug report: counts only, no
/// content or keys. Unreadable private objects are grouped by what they are,
/// who wrote them and whether the device that signed them was since removed,
/// since that is what decides whether a new device can ever get them.
Future<Map<String, Object>> historyReport(Node node) async {
  var privateHeld = 0, readable = 0, missingElsewhere = 0;
  final unreadable = <String, int>{};
  final perPerson = <String, Map<String, int>>{};
  var cursor = 0;
  while (true) {
    final page = node.store.insertedSince(cursor);
    if (page.isEmpty) break;
    for (final (rowid, o) in page) {
      cursor = rowid;
      if (o.isPublic || o.kind == 'keys' || o.data['payload'] is! Map) continue;
      if (!node.visible(o)) continue;
      privateHeld++;
      final ok = await node.holdsKeyFor(o);
      if (ok) {
        readable++;
        if (node.ownDevicesWithoutKey(o) > 0) missingElsewhere++;
      } else {
        final key =
            '${o.kind}/${o.author == node.person ? 'mine' : 'theirs'}/'
            '${node.revoked.contains(o.certificate.device) ? 'removed-device' : 'device-ok'}';
        unreadable[key] = (unreadable[key] ?? 0) + 1;
      }
      if (o.kind == 'message') {
        final peers = o.author == node.person
            ? o.audience.where((p) => p != node.person)
            : [o.author];
        for (final peer in peers) {
          final row = perPerson[peer] ??= {'messages': 0, 'unreadable': 0};
          row['messages'] = row['messages']! + 1;
          if (!ok) row['unreadable'] = row['unreadable']! + 1;
        }
      }
    }
  }
  String short(String id) => id.length > 6 ? id.substring(0, 6) : id;
  final people = <String, Object>{};
  for (final person in {
    ...perPerson.keys,
    for (final c in node.contacts.values)
      if (c.person != node.person) c.person,
  }) {
    people[short(person)] = {
      'profile': node.store
          .objects(kind: 'profile', author: person, limit: 1)
          .isNotEmpty,
      ...?perPerson[person],
    };
  }
  return {
    'privateHeld': privateHeld,
    'readable': readable,
    'unreadable': unreadable,
    'readableButNotGrantedToOtherDevice': missingElsewhere,
    'people': people,
    'ownDevicesInUse': [
      for (final c in node.contacts.values)
        if (c.person == node.person && !node.revoked.contains(c.device))
          short(c.device),
    ],
  };
}
