import 'package:ournet_core/ournet_core.dart';
import 'folder_sync.dart';

/// How a path compares between a newly connected folder and its drive
/// folder. Worked out from sizes and drive history only: nothing is
/// downloaded, so "identical" means the same size until the sync compares
/// the bytes.
enum FirstSyncKind {
  /// Folders on both sides, or files of the same size.
  identical,

  /// Only in the local folder.
  onlyHere,

  /// Only in the drive.
  onlyDrive,

  /// Files on both sides with different contents.
  differs,

  /// A file on one side and a folder on the other.
  clash,

  /// The local file matches an older revision of the drive file in size: the
  /// drive copy is probably newer.
  staleHere,

  /// Only in the local folder, matching a drive file deleted on another
  /// device.
  deletedElsewhere,

  /// The drive has unresolved concurrent versions; resolve them in drive
  /// history first.
  driveConflict,
}

/// Which copy is kept when the two sides differ.
enum FirstSyncChoice {
  /// Today's merge: both copies are kept, differing files as a conflict.
  both,

  /// The local copy wins. A drive-only entry is deleted from the drive
  /// (restorable from history); a differing drive file gets the local copy
  /// as a normal edit.
  here,

  /// The drive copy wins. A local-only entry is moved aside out of the synced
  /// folder; a differing local file is kept in drive history, then replaced.
  drive,
}

class FirstSyncItem {
  final String path;
  final FirstSyncKind kind;
  final FolderItem? local;

  /// The drive's current version, or for [FirstSyncKind.deletedElsewhere]
  /// its deletion.
  final DriveVersion? drive;
  const FirstSyncItem(this.path, this.kind, {this.local, this.drive});

  String get name => path.split('/').last;
  bool get directory =>
      local?.directory ?? drive?.isFolder ?? false; // Clashes: the local kind.
  int? get driveSize => drive?.data['size'] as int?;
  DateTime? get driveTime => drive == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(drive!.object.created);

  /// Which choices change anything for this item.
  List<FirstSyncChoice> get choices => switch (kind) {
    FirstSyncKind.identical ||
    FirstSyncKind.driveConflict => const [FirstSyncChoice.both],
    FirstSyncKind.clash => const [FirstSyncChoice.both, FirstSyncChoice.drive],
    _ => FirstSyncChoice.values,
  };

  /// The choice offered by default, from drive history.
  FirstSyncChoice get suggested =>
      kind == FirstSyncKind.staleHere || kind == FirstSyncKind.deletedElsewhere
      ? FirstSyncChoice.drive
      : FirstSyncChoice.both;

  /// What [choice] does to this item, for the review list.
  String effect(FirstSyncChoice choice) {
    if (!choices.contains(choice)) choice = FirstSyncChoice.both;
    return switch ((kind, choice)) {
      (FirstSyncKind.identical, _) => 'Same on both sides',
      (FirstSyncKind.driveConflict, _) =>
        'Left alone: resolve the drive conflict in history',
      (
        FirstSyncKind.onlyHere || FirstSyncKind.deletedElsewhere,
        FirstSyncChoice.drive,
      ) =>
        'Moved aside, out of the synced folder',
      (FirstSyncKind.onlyHere || FirstSyncKind.deletedElsewhere, _) =>
        'Added to the drive',
      (FirstSyncKind.onlyDrive, FirstSyncChoice.here) =>
        'Deleted from the drive',
      (FirstSyncKind.onlyDrive, _) => 'Added to this folder',
      (FirstSyncKind.clash, FirstSyncChoice.drive) =>
        'Local copy moved aside, drive copy added',
      (FirstSyncKind.clash, _) => 'Both kept as a conflict',
      (_, FirstSyncChoice.here) => 'Local copy replaces the drive copy',
      (_, FirstSyncChoice.drive) =>
        'Drive copy replaces the local copy (kept in history)',
      (_, _) => 'Both kept as a conflict',
    };
  }

  /// Whether [choice] moves the local entry aside or deletes the drive one.
  bool removes(FirstSyncChoice choice) =>
      choices.contains(choice) &&
      switch ((kind, choice)) {
        (
          FirstSyncKind.onlyHere || FirstSyncKind.deletedElsewhere,
          FirstSyncChoice.drive,
        ) =>
          true,
        (FirstSyncKind.clash, FirstSyncChoice.drive) => true,
        (FirstSyncKind.onlyDrive, FirstSyncChoice.here) => true,
        _ => false,
      };
}

class FirstSyncPlan {
  final String root;
  final String location;

  /// Parent-first, by path.
  final List<FirstSyncItem> items;

  /// Problems that leave a path out, such as unsupported names.
  final List<String> problems;
  FirstSyncPlan(this.root, this.location, this.items, this.problems);

  late final Map<FirstSyncKind, int> counts = {
    for (final kind in FirstSyncKind.values)
      kind: items.where((i) => i.kind == kind).length,
  };

  /// Whether connecting needs a person to choose. Not when everything matches
  /// or when one side is empty, since then nothing can be lost.
  bool get needsReview {
    final here = items.any((i) => i.local != null);
    final drive = items.any(
      (i) => i.drive != null && i.kind != FirstSyncKind.deletedElsewhere,
    );
    return here && drive && items.any((i) => i.kind != FirstSyncKind.identical);
  }

  /// The effective choice for each item: the nearest override on the item or
  /// a folder above it, then [preset], or each item's suggestion when
  /// [suggestions] is set. A choice an item does not offer keeps both.
  Map<String, FirstSyncChoice> resolve(
    FirstSyncChoice preset,
    Map<String, FirstSyncChoice> overrides, {
    bool suggestions = false,
  }) {
    FirstSyncChoice pick(FirstSyncItem item) {
      var path = item.path;
      while (true) {
        final chosen = overrides[path];
        if (chosen != null) return chosen;
        if (!path.contains('/')) break;
        path = path.substring(0, path.lastIndexOf('/'));
      }
      return suggestions ? item.suggested : preset;
    }

    return {
      for (final item in items)
        item.path: switch (pick(item)) {
          final c when item.choices.contains(c) => c,
          _ => FirstSyncChoice.both,
        },
    };
  }

  /// The decisions [FolderSync.connect] stores: each choice that differs from
  /// keeping both, with the state it was made against. A path that changes
  /// before the sync applies it keeps both instead.
  Map<String, Json> decisions(Map<String, FirstSyncChoice> choices) => {
    for (final item in items)
      if ((choices[item.path] ?? FirstSyncChoice.both) != FirstSyncChoice.both)
        item.path: {
          'keep': choices[item.path]!.name,
          'token': item.local?.token,
          'revision': item.drive?.data['revision'],
        },
  };
}
