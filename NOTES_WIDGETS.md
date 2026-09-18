# Notes, collaborators and Android widgets

Implemented 14 September 2026. This document supersedes older descriptions of
fixed group membership and read-only personal note dialogs.

## Try the features

Updated later on 14 September 2026 with Keep-style editing, the card grid and
the Notes board widget. The earlier Save-button editor described in older
notes no longer exists.

1. **Notes** shows cards in a staggered grid (a single column with the view
   toggle). Pinned notes come first; others are ordered by their latest edit.
   Search filters titles, text and list items as you type. The filter menu
   selects text notes, lists, links, files and photos, or **Removed**.
2. Tap **Take a note…** to write, or the checkbox button for a new list. Nothing
   is created until something is written. Writing saves after a short pause
   and when you leave the note; there is no Save button. Older inbox notes and
   checklists convert into editable notes when opened, as before.
3. In a list, Enter starts the next item and Backspace in an empty item removes
   it (hardware keyboards). Pasting several lines creates several items. Drag
   the handle to reorder. Checked items move to a collapsible **checked items**
   section. **More → Show/Hide checkboxes** converts between text and a list.
4. The palette sets a shared colour. Pins stay personal. Checking an item on a
   card, swiping a card away, or **Remove note** apply on screen at once; a
   removal offers **Undo**. Long-press or right-click a card for pin, colour,
   copy and remove.
5. **Collaborators** (person-plus) works as before, and the owner can now
   **Invite a new friend** from the same dialog; the new friend is preselected.
   Use this version on every participating device.
6. **More → Recovery** copies received earlier writing or selects a competing
   version into the editor. A banner offers **Review** when competing writing
   exists, and **Review draft** when collaborators changed while typing.
7. On Android, choose **Add Notes widget** in the Notes filter menu, or
   long-press the home screen and pick **OurNet · Notes**. It needs no setup:
   it lists pinned and recent notes with **+** (note) and **☑** (list) buttons.
   Tap a card to open that note. The gear hides contents. **Single note** and
   **Quick capture** remain available, and Single note keeps its
   hidden-by-default contents and interactive checkboxes.

## Editing, ordering and colour

- The editor autosaves 1.5 s after typing stops, on leaving the note, when the
  app is paused, and with Ctrl+S. List changes (check, reorder, remove, add,
  colour) are applied immediately on screen and published as one batch through
  `Notes.apply`. Each published text write becomes the editor's observed parent
  for the next save, so continued typing never creates a branch against this
  device's own writing. Unseen writing from others still becomes a branch.
- Every autosave is a signed object. There is no cap on how many a profile
  holds; the pause keeps this to roughly one object per burst of typing.
- A brand-new note that is closed within the first pause is still saved on
  leaving. If the process is killed before then, that first unsaved moment
  is lost, because new notes have no draft until they exist. Existing notes
  keep the encrypted draft behaviour.
- New registers: `check:<id>:order` (a string key, `[0-9A-Za-z]{1,64}`) and
  `color` (a lowercase palette name). Order keys are generated between
  neighbours and never end in `0`, so an item can always be placed before
  another. Items written before ordering existed sort first, by their first
  write, until a reorder renumbers the list. Concurrent moves of the same item
  converge like any register; colliding keys fall back to item ID order.
- **Compatibility:** earlier builds reject `order` and `color` operations as
  invalid content, so they neither display nor replicate them. Other writing
  still merges. Update every participating device.

## Notes board widget

- Rows come from the same encrypted native snapshot store. Dart publishes the
  board only while a board widget is placed: up to 40 notes (pinned, then most
  recently edited) with a 400-character body, eight unchecked items, counts and
  a light colour. The Android host never decrypts note history to draw.
- Board contents are shown by default, unlike Single note, because the board
  exists to glance at notes. The widget description and settings screen state
  that anyone who can see the home screen can read it. **Show note contents**
  can be turned off per widget; hidden boards keep only the capture buttons.
- Rows open notes through a mutable fill-in `PendingIntent` template with an
  explicit `MainActivity` component. Checking items from the board is not
  offered, matching Keep's multi-note widget; use Single note for that.
- Collection data uses `RemoteViewsService` (minimum SDK 24). Placing a board
  requests `configuration_optional` on Android 12 and later. Earlier versions
  show the one-checkbox settings screen once.

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
Configuration lists at most 200 notes by title or first line. Each snapshot includes at most 2,000 body
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
summaries and 200 checklist rows per note are exposed. Detailed document caching is limited to 16 documents
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
- Android instrumentation builds target **org.chozabu.ournet.profile**, never the
  everyday application ID. See `tool/check-note-widgets.ps1` for the real launcher,
  privacy, queue, encrypted persistence and process-restart checks.

## Validation record — Keep-style update, 14 September 2026

- `dart test` in `core`: 38 passed, including order-key properties, concurrent
  reorder/rename/add/colour convergence between collaborators, and batch limits.
- `dart test` in `transport`: 12 passed (native library on `PATH`).
- `flutter test` in `app`: 33 passed. Covers autosave conflicts, membership
  review, splitting and ordering items, saving on leaving, the card grid,
  optimistic card checks, search, swipe removal with Undo, board snapshots,
  friend discovery and the invitation screen.
- Android `NoteWidgetTest` on BV6600PRO (profile package): all five methods
  passed, including `boardListsNotesAndHidesContents` in a real widget host.
  By hand on the same phone: the board placed through **Add Notes widget**,
  showed a list note, and opened it and a new note. Enter created list items
  with the soft keyboard, and leaving saved the list.
- Windows profile runs of `responsiveness_test` and `photo_scroll_test` both
  pass their enforced budgets.
- On the BV6600 Pro, preview reads now run in parallel, storage waits for a
  pause in scrolling, and warm passes have no original reads or placeholders.
  Cold-pass frame p99 while generating all four previews still sits at the
  33.3 ms limit (22–45 ms across runs). See `PERFORMANCE.md`.
- Not yet checked by hand: drag reordering on a touch screen, and colour
  contrast of every palette entry in dark mode.
