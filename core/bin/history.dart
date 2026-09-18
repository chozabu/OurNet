import 'dart:convert';
import 'dart:io';

import 'package:ournet_core/ournet_core.dart';

/// What the everyday views cost as local history grows.
///
/// Builds temporary disk profiles at several sizes and times what a routine
/// refresh actually does: list the groups, open one, write to it, and answer
/// a peer's inventory. These are the paths that used to read and decrypt
/// every room, leave, inbox and group item on each call, which is what forced
/// a cap on how many objects a profile could hold.
///
/// The result worth reading is the shape across sizes, not any single number.
/// A view whose cost is set by the window it shows stays flat as the profile
/// grows; one that walks history does not. No personal profile is used.
///
///   dart run bin/history.dart [out.json] [--scales=5000,20000,60000]
Future<void> main(List<String> args) async {
  final output = args.where((a) => !a.startsWith('--')).firstOrNull;
  final scales =
      args
          .where((a) => a.startsWith('--scales='))
          .map((a) => a.substring(9).split(',').map(int.parse).toList())
          .firstOrNull ??
      const [5000, 20000, 60000];
  final report = <String, Object>{
    'utc': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystem,
    'dart': Platform.version,
    'scales': [for (final scale in scales) await measure(scale)],
  };
  final encoded = const JsonEncoder.withIndent('  ').convert(report);
  stdout.writeln(encoded);
  if (output != null) await File(output).writeAsString('$encoded\n');
}

/// One profile of about [objects] objects, spread over groups the way a used
/// profile is: many groups, and one busy group with a long history.
Future<Map<String, Object>> measure(int objects) async {
  final directory = await Directory.systemTemp.createTemp('ournet-history-');
  final path = '${directory.path}/profile.db';
  final identity = await LocalIdentity.create();
  final groups = (objects ~/ 200).clamp(4, 400);
  final perGroup = (objects ~/ (groups + 1)).clamp(1, 1 << 30);
  final result = <String, Object>{
    'objects': objects,
    'groups': groups,
    'itemsPerGroup': perGroup,
  };
  var node = Node(identity, Store(path: path));
  try {
    final everyday = Everyday(node);
    final build = Stopwatch()..start();
    final rooms = <EverydayItem>[];
    for (var g = 0; g < groups; g++) {
      final room = await everyday.createRoom('Group $g', []);
      rooms.add(room);
      for (var i = 0; i < perGroup; i++) {
        await everyday.write({'type': 'note', 'text': 'Item $g/$i'}, room: room);
      }
    }
    // The inbox a person accumulates alongside their groups.
    for (var i = 0; i < perGroup; i++) {
      await everyday.write({'type': 'note', 'text': 'Inbox $i'});
    }
    result['buildMs'] = build.elapsedMilliseconds;
    result['storedObjects'] = node.store.count;
    result['storedObjectMiB'] = node.store.objectBytes / (1024 * 1024);

    // A fresh node is a cold start: nothing is projected yet.
    await node.close();
    node = Node(identity, Store(path: path));
    final cold = Everyday(node);
    final busy = rooms.last;
    result['coldRoomsMs'] = await time(() => cold.rooms());
    result['warmRoomsMs'] = await time(() => cold.rooms());
    result['openBusyGroupMs'] = await time(() => cold.items(busy));
    result['reopenBusyGroupMs'] = await time(() => cold.items(busy));
    result['openInboxMs'] = await time(() => cold.items());
    result['writeMs'] = await time(
      () => cold.write({'type': 'note', 'text': 'Measured'}, room: busy),
    );
    result['secondWriteMs'] = await time(
      () => cold.write({'type': 'note', 'text': 'Measured again'}, room: busy),
    );
    result['membersMs'] = await time(() => cold.members(busy));
    result['inventoryMs'] = await time(() async => node.inventory());
    result['rssMiB'] = ProcessInfo.currentRss / (1024 * 1024);
  } finally {
    await node.close();
    await directory.delete(recursive: true);
  }
  return result;
}

Future<double> time(Future<void> Function() action) async {
  final watch = Stopwatch()..start();
  await action();
  return watch.elapsedMicroseconds / 1000;
}
