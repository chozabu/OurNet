import 'dart:async';

import 'drive.dart';
import 'model.dart';
import 'everyday.dart';
import 'node.dart';
import 'notes.dart';

/// Hands this person's other devices everything earlier that they could not
/// read on their own: chats (by key grant), and files, inbox, groups and notes
/// (by re-issue). Returns how many chat keys were granted; [progress] is told
/// that count as it grows.
///
/// Whether a device should read what came before it is its owner's choice, so
/// callers ask first; pairing asks with "Share history" and the device list
/// offers it afterwards.
Future<int> shareAllHistory(Node node, {void Function(int)? progress}) async {
  final granted = await node.shareKeys(history: true, progress: progress);
  await Drive(node).shareHistory();
  await Everyday(node).shareHistory();
  // Re-encrypted for the devices already added: without this their groups
  // and notes stay unreadable there for good, since a later edit arrives in a
  // space they have no record for.
  await Everyday(node).shareRooms();
  await Notes(node).shareNotes();
  markHistoryOffered(node);
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
