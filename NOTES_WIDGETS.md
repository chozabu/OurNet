# Notes, collaborators and Android widgets

Implemented 14 September 2026. This document supersedes older descriptions of
fixed group membership and read-only personal note dialogs.

## Try the features

1. In **Notes**, save a text note, or choose **Lists**, name a list and add items.
   Tap a note/list title to open its editor. Existing personal inbox notes are
   converted when opened; opening an old checklist converts its same-name items
   together. Its old encrypted records remain stored, marked as moved. Old group
   conversations and group lists keep their existing behaviour.
2. In the editor, choose **Collaborators** (person-plus). Select existing friends
   and save. Only the owner can change collaborators; other people can **Leave
   note**. Keep both applications open and connected for replication. Use this
   version on every participating device.
3. Edit text and press **Save**, or check items directly. The Notes list shows
   shared notes and personal notes together, with collaborator indicators and
   the first three checklist items. Pins are personal. Search includes the
   bounded note preview; open the note to read its entire contents.
4. Use **Recovery** (history icon) to copy received earlier writing, or select a
   competing text version into the editor and save it. Combine versions manually
   when both contain useful writing. Removed notes and locally received copies of
   notes you left are under **Notes → Removed**. Restore a removed note in its
   editor; removed checklist items can be restored from Recovery.
5. On Android, long-press the home screen, choose **Widgets → OurNet → Single
   note**, and select a note/list. Contents are hidden by default. Enable **Show
   contents on the home screen** to show text and interactive checkboxes. Anyone
   looking at the home screen can see enabled contents. Use the gear to change
   the selection/privacy setting; long-press and resize using the launcher.
6. Tap a checkbox to save a desired state locally, including with OurNet closed
   and offline. Tap note text or **Open in OurNet** to edit that specific note.
   **Quick capture** provides separate text-note and checklist actions.
   Old inbox notes become selectable after opening them once in this version.

## Conflict and membership semantics

- Every new personal/shared note is one owner-bound `room2:` identity. Sharing
  changes its owner-signed membership epoch, not its identity. Existing
  `Everyday` membership, device certificates, encryption, signed objects, and
  generic transport replication are reused.
- `note_op` registers hold title, body, each checklist item's text, checked state,
  and deletion flags independently. Item IDs never depend on row position.
  Edits name the same-field versions observed by the editor. Unobserved competing
  text stays as a live branch. Heads use Lamport ordering and object-ID tie-break
  for a consistent display; older writing remains in local received history.
- Checking an item cannot replace its text or another item's state. Concurrent
  checked-state changes resolve by Lamport/object ID. Repeated widget deliveries
  are desired-state operations with durable request IDs, not repeated inversions.
- Note/item deletion is a separate remove-wins register. Concurrent writing does
  not resurrect a removed note/item; it remains recoverable. Restore explicitly
  observes deletion heads. A stale editor saving after it learns of deletion is
  rejected and its local draft remains available.
- Membership updates copy **current register heads, including competing text and
  tombstones**, into a fresh encrypted epoch before publishing the new membership.
  New collaborators receive that current state, not the preceding revision log.
  Checkpoints are accepted only from the owner. If checkpoint preparation fails,
  the previous membership remains current; unreachable prepared records may use
  local object quota. Concurrent owner membership changes resolve by the existing
  generation/object-ID rule; an owner's losing epoch is retained as local history.
- Old-epoch work does not modify a new epoch, even from a continuing collaborator.
  Locally received old-epoch writing is in Recovery. An unsent text draft retains
  its observed epoch/parents and requires review before applying to a new epoch.
  A leave records the departing person's accepted operation IDs: their received
  writing remains, but other late operations from that epoch are recovery-only.
- Revocation is not remote erasure. Removed people may keep/decrypt copies and
  old-epoch work they already had keys for. Offline peers can still send old
  content to former members until they learn of the change. New-epoch content
  excludes removed recipients. Adding a device after encryption does not
  retroactively give it keys to existing shared-note history; this retains the
  existing private-group enrollment limitation.

## Android lifecycle and local storage

Widgets render a native, app-private snapshot encrypted with an Android Keystore
AES-GCM key in `noBackupFilesDir`. They do not open Flutter, read original images,
decrypt note history or start networking to draw. Snapshots/outbox share an
atomic encrypted file (512 KiB limit). A single native worker has a 64-job queue;
at most 128 pending checkbox requests and 16 configured note widgets are accepted.
Configuration lists at most 200 notes. Each snapshot includes at most 2,000 body
characters and 20 checklist previews (160 characters each); widget height shows
up to 12 rows and links to the full note. Privacy-hidden snapshots omit contents.

Each tap commits before changing the displayed checkbox. Tokens reject duplicate
or stale rendered actions; request IDs also deduplicate after Dart publication
and process restart. Pending work outlives widget deletion. A profile token binds
snapshots, operations and deep links to the original local identity/profile.
Changing profile clears the displayed snapshot; widgets are not silently rebound.

The native outbox says **Saved here · Open OurNet to sync**. When the existing
Flutter engine is available, a coalesced bridge drains it through `Notes.edit`;
otherwise it drains on the next app start/resume. Local core publications enter
the normal transport retry flow. Membership/deletion errors keep the request in
widget settings with its note/item label, retry and explicit discard actions.
The UI does not promise that another device has received a pending edit.

Android networking still stops on pause when no call is active. There is **no
push wakeup or headless remote replication** in this implementation. Remote edits
refresh widgets after the app receives them while running/resumed. Scheduled
polling would not guarantee immediate delivery under Doze either. Force-stopped
apps are subject to Android's launcher/broadcast restrictions until reopened.

Notes refresh uses insertion-cursor pages of at most 128 relevant objects,
per-note indexed queries, cached bounded list projections, and 32 ms coalescing.
It does not scan unrelated inbox/file history to render widgets. Up to 200 note
summaries and 200 checklist rows per note are exposed; the existing 10,000-object
store quota still applies. Detailed document caching is limited to 16 documents
of less than 512 KiB each. Drafts use the existing encrypted, debounced DraftStore.

## Official design references

- [Google Keep: notes on Android home screens](https://support.google.com/keep/answer/13302793?hl=en): single-note selection, direct checkbox interaction, opening text in the app, and quick capture.
- [Google Android announcement](https://blog.google/products-and-platforms/platforms/android/new-android-features-february-2023/): single-note home-screen interaction.
- [Android widget configuration](https://developer.android.com/develop/ui/views/appwidgets/configuration) and [update/lifecycle guidance](https://developer.android.com/develop/ui/views/appwidgets/advanced).

OurNet uses rounded green surfaces and clear note/checklist actions adapted to
its palette, not a pixel-identical Keep clone. Native broadcasts use `goAsync`
with bounded worker work; an explicit immutable PendingIntent targets each action.

## Validation commands

- `tool/check.ps1 -Performance -Device windows`
- `flutter drive --profile -d BV6600PROEEA004660 --driver=test_driver/performance.dart --target=integration_test/responsiveness_test.dart --dart-define=PERF_ENFORCE=true` (from `app`)
- Repeat with `integration_test/photo_scroll_test.dart`. The photo fixture now
  includes a shared checklist row alongside the existing notes and images.
- Android instrumentation builds target **org.ournet.ournet.profile**, never the
  everyday application ID. See `tool/check-note-widgets.ps1` for the real launcher,
  privacy, queue, encrypted persistence and process-restart checks.

See the validation record below for actual results and outstanding limitations.
