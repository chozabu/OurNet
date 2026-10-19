# Try private drive between your devices

OurNet 0.2 adds an app-managed private drive. Files and folders are encrypted for
devices enrolled under the same person identity. You can import, replace and export files through OurNet, or connect a local
folder for two-way synchronization. Drive metadata syncs between connected
devices independently of each device's chosen local folder.

## Pair two profiles or devices

1. Keep Alice as the owner. Start a **fresh** second profile, for example
   `tool/run.ps1 -Profile alice-phone`. Your existing Bob profile remains a
   different person and is not part of Alice's private drive.
2. On Alice, open Profile → **Add device**.
3. On the fresh device, choose **Connect to my existing profile** and scan the
   QR code, find Alice nearby, or paste Alice's invitation.
4. Compare the code on both screens and approve on Alice. Contact exchange is
   automatic. Their person IDs match while device IDs differ. The root secret
   remains on Alice. Leave **Share existing drive history** enabled to share old files.
5. Open Files → Private drive. Create a folder and add a small file on Alice.
   The other device should see the entry after sync. Enable **Keep files offline
   on this device** there to download an encrypted copy automatically.
6. Disconnect Alice. On the second device, choose the file's menu → Export file
   and compare it with the original. A downloaded copy works offline.

If you created files before enrolling the second device, use **Share history with
new devices** on a device that can already read them. This re-encrypts manifests
for the known device certificates, preserving revision identities and ancestry.
It applies to drive history; old private chat history still has no migration UI.

## Revisions and conflicts

- Upload new version replaces a logical file while keeping earlier revisions.
- Rename and Move create revisions; folders and metadata sync across devices.
- Offline edits to the same entry create concurrent versions. Neither is silently
  discarded. Open Version history, export either version, and choose **Use this
  version** to create a revision resolving the currently known conflict.
- History & deleted items lets you restore old versions or deleted entries.
- Delete removes an entry from the live drive, not its retained history or
  previously exported copies. Non-empty folders must be emptied first.
- New files with the same name are separate entries. Names are not file IDs.

The current limits are 64 MiB per file and the storage limit in Settings
(objects and chunks together, 20 GiB by default). The number of signed objects
a profile holds is not capped. History resharing consumes additional objects. Cleanup/retention, large transfers and background Android delivery remain work.
Use your own test files first; the protocol and recovery model are still evolving.


## Connect an ordinary folder (Windows and Android)

On the desktop, open **Files → Private drive → Sync a folder**, choose e.g.
`D:\Pixel8Pro`, and confirm its drive name and the connection preview. The
original directory stays where it is. On the phone, open the resulting
**Pixel8Pro** folder and choose **Connect to local folder**. Android's system
picker can grant access to an existing or newly created **Documents/Pixel8Pro**
folder. The persisted document-tree permission is used directly; OurNet never
converts the URI to an assumed `/storage/...` path or requests all-files access.

Without a local connection the folder remains browsable inside OurNet; the
existing offline switch retains encrypted copies in app storage. A connected
folder contains ordinary decrypted files accessible through the OS. A connection
is local to this device and never dictates another device's location.

* Changes and deletions propagate individually in both directions. Deleting
  `old.txt` on the desktop and adding `new.txt` on an offline phone produces both
  changes after synchronization: `old.txt` disappears and `new.txt` is on both.
* Concurrent edits, including delete-versus-edit, retain separate revisions.
  Local contents are preserved while conflicted; **Version history → Use this
  version** resolves content conflicts and the chosen version is then applied.
* Connecting a folder to a drive folder when both have files first shows a
  review: what is only on this device, only in the drive, the same, different,
  a file against a folder, an older copy of a drive file, or a file deleted from
  the drive elsewhere (worked out from sizes and drive history; nothing is
  downloaded). Choose **Keep both**, **This device wins** or **Drive wins** for
  everything, then per folder or file. Keeping both is the merge: differing
  files become concurrent revisions, with no timestamp winner. The losing copy
  is never lost: a replaced local file is kept in drive history, a drive entry
  this device wins over is deleted there (restorable from history), and a local
  entry the drive wins over moves to a sibling `<folder> (not synced)` folder
  (on Android, `.ournet-not-synced` inside the folder, since a document tree
  cannot reach outside itself). A choice applies only while the entry is as it
  was in the review, and only until the first pass completes. With one side
  empty, or only identical entries, there is no review.
* A local file byte-identical to the drive's copy adopts its revision, and one
  identical to an earlier revision is brought up to date, without a conflict.
* **Sync now** checks a connection immediately. Desktop filesystem notifications
  trigger debounced checks; a 15-second reconciliation catches missed events and
  changes to Android document trees (every 5 minutes while the app is in the
  background; drive changes still sync at once). Reopening the app also
  schedules a check. Mobile work is not guaranteed while OurNet is suspended
  or closed.
* A folder deleted locally lists the entries deleted with it (`removed`, up to
  1,000). Records arrive in pages, newest first, so another device may get the
  folder's deletion before its children's; it then waits for those instead of
  restoring the folder as a conflict.
* **Stop syncing here (keep files)** stops synchronization without deleting either copy.
  Missing roots, revoked permissions, incomplete provider listings, unsupported
  names and case collisions fail safely instead of looking like mass deletions.
* Each device persists per-entry revision/token baselines separately from drive
  history. Only new drive records are decoded when maintaining the drive index.
  Transfers run serially for folder connections using bounded temporary files;
  encryption and blob hashing continue to use the node's attachment worker.

Current boundaries: the 64 MiB file limit and the storage limit still apply; the record count is not capped. Local filename changes are represented as delete/add.
Drive-side renames and moves preserve entry identities and are applied to local
paths, including nested directories and case-only Windows renames. Concurrent
file edits still retain separate revision branches; name collisions never overwrite
an existing destination.
Symlinks/junctions, unsupported portable filenames, nested/overlapping local
connections, native files-on-demand placeholders, and a mobile background service
are not supported. A link or unsupported name that was never synced is skipped
and reported while the rest of the folder keeps syncing. SAF providers must expose modification timestamps and support
safe document creation/rename; unsupported providers report a connection error.
Local change detection uses filesystem/provider metadata, so edits deliberately
preserving all reported size/timestamps may not be detected.

Android replacement stages a new document and renames the old document to a
`.ournet-*.backup` before committing. An interrupted provider operation may leave
that backup for manual recovery; reserved `.ournet-*` entries are never imported.
Deletion is nonrecursive and refuses folders containing unaccounted-for files.
History remains recoverable within the existing retention model; folder sync is
not an independent backup.

### Validation

`transport/test/folder_sync_test.dart` exercises paired-device additions,
deletions, conflicts, resolution, nonempty destinations, disk-store restarts,
missing roots, disconnects, rename/move races, deleted parents with new children,
and compare-before-write protection. Existing endpoint
transfer tests cover encrypted chunk delivery. `core/test/drive_test.dart` checks
that repeated drive reads do not revisit retained revisions.

The note-history and photo-scroll profile journeys now include an active folder
connection. `integration_test/folder_provider_test.dart` is an interactive Android
SAF acceptance test: run it in the profile application with `SAF_PICKER_TEST=true`
and choose an empty disposable folder. It imports a phone file, replaces it,
applies a drive deletion, renames and moves nested entries, and removes only its
own files.

Verified on 2026-09-16: the full Windows check (package tests, analysis and all
four profile performance journeys), all 14 folder-sync regressions, and the
Android document-provider acceptance test on a physical Pixel 8 Pro passed.
The Pixel history/editor profile journey also passed with folder import active:
camera-return frame-stage p95 3.751 ms, p99 10.856 ms, worst sampled event-loop
delay 22.658 ms (16.67 ms frame and 100 ms delay budgets). The first Android
timing attempt stopped on a test-cache symlink; both disk-backed performance
fixtures now resolve their temporary directory paths. That incomplete attempt
also recorded initial-sync raster p95 16.825 ms, slightly above the frame budget;
the completed rerun recorded 2.033 ms without changing timing thresholds.
Android photo-scroll timing and macOS/Linux platform validation were not run.
