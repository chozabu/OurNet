# Repeatable performance checks

## Responsiveness acceptance checks

Responsiveness is separate from completion time: attachment work may take time,
but typing, saving a note, filtering and scrolling must continue to work.

Run the normal correctness/analysis suite with `tool/check.ps1`. On a consistent
Windows machine or physical Android device, also run:

```powershell
.\tool\check.ps1 -Performance -Device windows
# Use the device ID reported by flutter devices for physical Android hardware.
```

This adds a **profile-mode Flutter integration test**. It creates a temporary disk
profile with 60 notes and a deterministic 1024×1024 noisy PNG, then imports the
image while typing, saving, filtering and scrolling. It checks that the image and
typed note were actually saved. No personal profile or user image is used.
Add `--dart-define=SHARED_NOTES=1000` to run the same journey with 1,000 more
notes, as after a large Keep import; the notes list loads in pages, so the
budgets are the same.
Results are written by the integration driver to
`app/build/integration_response_data.json`, including results from failed timing
gates. Startup frame callbacks are flushed before the interaction and pending
frame callbacks are collected afterward; the engine batches these callbacks.

The acceptance budgets, enabled by `PERF_ENFORCE=true`, follow the display's
reported refresh rate (`1000 / refreshRate` ms; 16.7 ms at 60 Hz, 8.3 ms at
120 Hz). The reports record `refreshRateHz` and `frameBudgetMs`:

| Measurement | Budget |
|---|---:|
| p95 of the slower frame stage (build or raster) | < 1 frame interval |
| p99 of the slower frame stage | < 2 frame intervals |
| Worst observed event-loop timer delay | <100 ms |

At least 11 measured frames are required. These are provisional targets, not a
claim that every supported device meets them. A 50 ms timer samples event-loop
delay; this is not a direct input-to-paint latency measurement. Run comparisons
without builds/tests in parallel, and compare repeated runs on the same hardware.
Do not relax a failing budget merely to make a run pass.

### Notes photo scrolling

`integration_test/photo_scroll_test.dart` is the repeatable photo-scrolling
regression journey. It generates deterministic photo-like JPEGs (no personal
data), imports them through the real encrypted attachment pipeline into a
temporary disk profile, then scrolls Notes with finger-speed drags and flings:

* `PHOTO_SCENARIO=four` (default): four 12 MP (~3.8 MB) photos between six notes.
  One **cold** pass (no stored previews, empty image cache), `WARM_CYCLES`
  (default 5) **warm** passes, and a **relaunch** pass (app recreated with an
  empty image cache but durable previews). Warm passes must perform zero
  original chunk reads and zero image decodes; relaunch must read no originals;
  RSS may not grow by 32 MiB or more across warm passes.
* `PHOTO_SCENARIO=large`: 300 photos (2 MP) and 700 notes. Each pass makes
  `PASS_GESTURES` (default 60) downward gestures and returns to the top. Two
  final passes run while two photos are imported through the UI and 96 notes
  from another device of the same person are received in pages.

Per pass it reports frames over budget, build/raster/frame-stage percentiles,
event-loop delay (10 ms timer), original chunk reads (decryptions), image codec
instantiations, previews generated, RSS, image cache size, and the share of
50 ms samples in which a loading placeholder was visible in the list viewport.

```powershell
cd app
flutter drive --profile -d DEVICE_ID --driver=test_driver/performance.dart --target=integration_test/photo_scroll_test.dart
flutter drive --profile -d DEVICE_ID --driver=test_driver/performance.dart --target=integration_test/photo_scroll_test.dart --dart-define=PHOTO_SCENARIO=large --dart-define=WARM_CYCLES=2
```

Android profile builds use the application ID `org.chozabu.ournet.profile`
(label "OurNet profile"), so `flutter drive --profile` never replaces the
everyday debug/release app or its data. Some devices intermittently restart the
first launch after installation, which makes the driver fail with
`Sentinel kind: Collected`; rerun in that case. The first run on a slow phone
spends minutes generating the fixture photos before the first frame.

To collect a result without enforcing timing budgets:

```powershell
cd app
flutter drive --profile -d windows --driver=test_driver/performance.dart --target=integration_test/responsiveness_test.dart
```

The test uses live frame scheduling. Add `--dart-define=PERF_TRACE=true` to
include a DevTools timeline in the report, and `--trace-skia` when investigating
Windows shader compilation. Trace collection adds overhead, so collect normal
budget results separately from diagnostic traces.

For the actual disk attachment pipeline without Flutter, run from `transport`:

```powershell
dart run bin/responsiveness.dart ../RESPONSIVENESS_BASELINE.json
```

This measures cold worker startup plus an 8 MiB encrypted import, verified preview
read, event-loop delay and RSS (including the fixture buffers and benchmark
runtime, not just the app). It includes byte-for-byte verification overhead in
the preview phase. It does not measure network transfer, image decoding or frame
rendering. Compile it with `dart build cli -t bin/responsiveness.dart` for AOT
comparisons; label JIT and AOT results separately.

### History size

`core/bin/history.dart` is the repeatable check that reading a view costs the
window it shows rather than the whole profile. It builds temporary disk
profiles at several sizes, through the real signing and encryption path, and
times what a routine refresh does: list the groups, open one, write to it, read
its members, and answer a peer's inventory. No personal profile is used.

```powershell
cd core
dart run bin/history.dart ../HISTORY_BASELINE.json --scales=5000,20000,60000
```

The result worth reading is the shape across sizes, not any single number: a
view whose cost is set by its window stays flat as the profile grows, and one
that walks history does not. Building the profiles dominates the runtime
(every object is really signed and encrypted), so expect tens of minutes for
the larger scales. `HISTORY_BASELINE.json` records a run.

`HISTORY_BASELINE.json` records a Windows Dart JIT run at three sizes, the
largest six times the old cap:

| Measurement | 5,017 objects | 20,098 objects | 60,199 objects |
|---|---:|---:|---:|
| Groups in the profile | 25 | 100 | 300 |
| Stored object MiB | 5.8 | 23.5 | 70.6 |
| Open the busy group, cold (ms) | 214 | 214 | 208 |
| Reopen it (ms) | 2.1 | 1.7 | 2.4 |
| Open the inbox (ms) | 208 | 214 | 207 |
| Write to the busy group (ms) | 15.8 | 17.0 | 20.8 |
| Read its members (ms) | 2.6 | 3.6 | 5.4 |
| Answer a sync inventory (ms) | 32 | 25 | 27 |
| List the groups, projected (ms) | 0.19 | 0.24 | 0.55 |
| List the groups, first load (ms) | 36 | 147 | 371 |
| RSS (MiB) | 379 | 421 | 438 |

Opening a group, opening the inbox, writing, and answering an inventory are
flat across a twelve-fold change in stored objects: they cost what they show.
Listing the groups grows with the number of **groups** (25, 100, 300), not
with history — which is the intended shape, and the first load of that list
also decrypts each group's record once per process, so it is the one figure
that a profile with very many groups should be judged on.

These are one machine's measurements, not a speedup claim: the same journeys
could not be run past 10,000 objects at all before, so there is no before
column to compare against. Building the profiles dominates the run — the
60,000-object profile takes about twenty minutes to write, because every
object is really signed and encrypted.

The Flutter journeys can also be run with a profile past the old cap, which
was previously impossible: building one failed on the quota rather than on
time, so the app was never measured there.

```powershell
cd app
flutter drive --profile -d DEVICE_ID --driver=test_driver/performance.dart --target=integration_test/note_history_test.dart --dart-define=NOTES=200 --dart-define=EDITS=60
```

That builds roughly 12,000 note objects before the measured camera return.
Setup dominates the run; the budgets are the same, because the interaction is
supposed to cost what it shows rather than what is stored.

## Performance architecture and review rules

- Each node lazily owns one attachment isolate. It serializes chunk encryption,
  hashing, verification, decryption and blob database work through a worker-owned
  connection for disk profiles. Chunk producers await each response, and closing
  a node drains accepted requests before closing the database. In-memory test
  stores keep blob storage in the caller; they still offload cryptography.
- SQLite triggers maintain blob usage across connections and transactions. An
  import no longer sums every stored blob for each chunk. Existing databases gain
  this accounting automatically without changing signed content or encryption.
- Lists never display originals. Image rows use durable **encrypted previews**
  (longest edge 640 px, JPEG, PNG when translucent; earlier 960 px previews are still read) stored in a separate
  `previews` table, sealed with the file's own key and bound to the object ID
  (AEAD associated data), bounded to 128 MiB and evicted least-recently-used.
  `ThumbnailImage` uses the object ID as a stable image-cache key, and decodes
  at display resolution, so recreated rows are served synchronously from
  Flutter's bounded image cache; after eviction only the small preview is read.
- A missing preview is generated at most twice concurrently. The locally
  stored original is read, verified and decrypted on a short-lived isolate
  (`BlobWorker.readLocal`), or through the worker when chunks must be fetched.
  The downsampled engine decode is shown immediately, previews finishing
  together reach the screen a frame apart, and the generation slot is released.
  Up to two decoded previews then wait to be stored, one at a time after a
  pause in frames: pixel read-back, compression in a short-lived isolate, and
  encryption/storage on the worker. Imports and received synced files prepare
  previews in the background. Requests for rows scrolled away before their turn
  are demoted to background preparation (bounded queue) rather than dropped.
- Original reads (full-size viewing, preview generation) allow two active jobs
  and at most 32 outstanding distinct requests per node. Duplicate in-flight
  reads share one result. Plaintext originals are not retained or persisted.
- Stored objects are immutable, so the store keeps a bounded parsed-object cache
  (IDs are selected first; only unseen wires are parsed), object and evidence IDs
  are computed once, and the node keeps a bounded cache of decrypted payloads
  (32 MiB of ciphertext). Notes/group/drive rebuilds no longer repeat public-key
  decryption for every item. Long history loops (records, drive entries, sync
  offers and received pages) yield to the event loop every 4 ms between items;
  each item remains atomic.
- Sync cost must not grow with history for routine changes. The store keeps
  each object's evidence digest current, so inventory and offer skip reconciled
  objects without hashing or parsing them. Only records not already stored are
  verified, in an isolate. Handoffs and receipts are signed in batches off the
  UI isolate, and a page's writes commit in transactions.
- **No view reads more than it shows, and no structure grows with the stored
  object count.** This is what replaced the 10,000-object cap: the cap bounded
  rows rather than bytes, so it bounded nothing real (an object runs to 256 KiB)
  while it did bound the product. A person's own writes are no longer limited;
  what a peer can drive this device into storing is, in bytes, with object
  usage maintained by trigger exactly as blob usage is. `receivedBudget` in
  settings raises or disables that, and own writes are never refused by it.
- Group and note views are per-space. `Everyday` keeps one projection per node,
  fed by an insertion cursor: rooms and leaves are held (membership is derived
  from them and there are few), while items are read from the space being
  shown and never retained. Listing groups, opening one, reading its members
  and writing to it each cost that space, not all of history. A write used to
  walk every room, leave, inbox and group item several times over.
- A read of an incremental projection must be free when nothing has changed,
  and must not be asynchronous either. Views read these several times per
  rebuild, so queueing a pass per read leaves a view rescheduling itself for
  as long as reads keep arriving — which is a hang, not a slowdown. The gate
  is the store's insertion cursor, plus the blocked set, because blocking
  stores no object and so does not move the cursor.
- When a pass is needed, callers **join the one in flight** rather than queue
  behind each other, as the notes and drive projections do. A chain of passes
  fills faster than it drains while a view is rebuilding, and a write then
  waits behind every queued one; under a widget test's fake clock it never
  drains at all. Joining means a caller can observe a pass that began just
  before its own write, which is what a Lamport counter tolerates — a repeated
  value breaks the tie by object ID, and every write notifies.
- A cursor must move past everything it **scanned**, not past the last record
  it wanted. Asking for a kind walks the rows in between, so a cursor left at
  the last match rewalks everything written after it on the next pass — and a
  profile holding none of that kind rewalks all of it, on every change. This
  is the one that turns an incremental view back into a quadratic one, and it
  does not show up in a profile that happens to hold the kind being sought.
- Visibility is applied when a record is read, never baked into a projection:
  `Node.visible` depends on the clock, because objects expire. Blocking gives
  visibility back rather than taking it away, and no cursor walks backwards, so
  a change of who is blocked reprojects instead.
- The Lamport counter a write numbers itself with is only found inside item
  payloads. Decrypting all of them to learn one number is done once per device
  and the result is stored with its cursor, rather than repeated on each start.
- Sharing fields are a trigger-maintained derived index (`object_routes`), like
  the message routing index, so an inventory page is an index scan instead of
  re-extracting JSON from every stored object. No route is held in memory
  between calls, and a sync page no longer re-sorts every object it holds.
- Evidence digests are a bounded cache over an indexed lookup rather than every
  object's evidence held at once, and offers walk a creation-time window in
  keyset pages rather than materialising it.
- Search has no index to narrow it, so it does read all of history; it does so
  in pages, with pauses, and does not present a fixed slice as though it were
  everything.
- Reads whose correctness depends on seeing all of something read all of it,
  in pages: one note's operations and one group's items. A limit there would
  not shorten a view, it would drop live records — whatever was written once
  and never revised, or the entries last written about longest ago. Showing a
  very long group lazily is separate work; the notes list is already paged
  that way, a group's item list is not yet.
- UI lists share per-build derived data (profile names, unread objects, forum
  definitions and moderation, reply counts) instead of rescanning history per
  row. Delivery receipts and new-activity notifications are consumed by
  insertion cursor, not by rescanning or by remembering every stored ID. File presence is one query per file and positive results are remembered.
- Notes imports show local-save progress and use a separate action state, keeping
  note submission and navigation available. Text paste/import captures its
  destination before awaiting platform work.
- Data notifications collapse into 32 ms refresh batches. Delivery-label scans
  have one active run plus at most one pending rerun, and network status updates
  no longer trigger those scans. Notes queries select relevant object kinds
  before applying their result limit.
- Settings → Copy diagnostics includes local, bounded frame/event-loop samples
  and build mode. Percentiles cover the latest 600 samples; the maximum and count
  cover the monitored session. Sampling pauses when the app is not resumed.
  No content, paths, or keys are included in these performance fields.

For new heavy features, put CPU/blob work behind the worker boundary, bound queue
and memory growth, provide immediate operation-specific feedback, and extend the
integration journey when adding a new interaction. Keep deterministic correctness
and concurrency checks in the normal suite; run hardware timing gates for release
validation. `attachment.import` and `attachment.preview` are DevTools timeline
spans.

This is an initial performance foundation. Metadata SQL, signature
verification and first-time record decryption still run on the main isolate
(time-sliced). Group, note and drive views are now incremental projections
over per-space reads, so a refresh no longer processes broad history; what
remains for a first load is decrypting the records a view actually shows, and
one migration pass per device to record the counter described above.
Windows first-use rendering, sync-under-load scenarios,
direct input-to-paint measurement, cancellation and physical Android validation
remain follow-up work, as does the cost of an inventory for a peer that can see
very little of a large profile: the sharing index makes that an index scan, but
it is still a scan. The new measurements should guide that work.

## Recorded validation of the foundation

All three package analyzers and **54 correctness tests** passed (23 core, 9
transport, 22 app). The Windows profile journey passed its functional assertions:
the image and a note typed during import were both saved, and filters remained
usable. **The timing gate is still failing**, and has not been weakened.

`UI_RESPONSIVENESS_BASELINE.json` records the final local Windows profile run:

| Measurement | Observed |
|---|---:|
| UI build p95 | 8.904 ms |
| Raster p95 | 48.694 ms |
| Raster p99 | 87.145 ms |
| Worst sampled event-loop delay | 67.579 ms |

These are one run's measurements, not a before/after speedup claim. Diagnostic
Skia traces identified first-use shader compilation in some long raster frames,
including roughly 31–38 ms compilations. The rendering budget remains an open
release-quality issue. Android hardware timing has not been validated.

`RESPONSIVENESS_BASELINE.json` separately records a Windows Dart JIT run of the
8 MiB disk pipeline: cold import 869.980 ms, preview plus verification 626.468 ms,
and maximum sampled timer delays of 65.147 ms and 12.142 ms respectively. This
benchmark does not substitute for the failing Flutter rendering gate.

## Recorded validation of Notes photo scrolling

`PHOTO_SCROLL_BASELINE.json` records per-pass results of `photo_scroll_test`
before and after durable encrypted previews, stable image keys and the history
caches. Single profile-mode runs; both phones reported 60 Hz. Before/after were
measured on the same phone with the same test (the "before" build used the prior
library code). Frame values are the slower of build/raster per frame.

**Blackview BV6600 Pro** (Helio P35, 4 GB, Android 11, 720×1440):

| Four 12 MP photos | Before | After |
|---|---:|---:|
| Original chunk reads per warm pass | ~110 | 0 |
| Image decodes per warm pass | 0–1 (most never finished) | 0 |
| Placeholder visible, warm passes | 32–40 % (≤650 ms) | 0 % |
| Placeholder visible, first-ever pass | 40 % (600 ms) | 21 % (600 ms) |
| Frame p95, warm passes | 11.5–22.3 ms | 12.2–15.0 ms |
| Frame p95, first-ever pass | 19.3 ms | 14.7 ms |
| Relaunch (durable previews, empty cache) | 113 reads | 0 reads, 3 small decodes |

| 300 photos + 700 notes (60-gesture window) | Before | After |
|---|---:|---:|
| Notes list rebuild on the UI isolate | 4,119 ms | 64 ms |
| Original reads / decodes per warm pass | 592 / 74 | 0 / 0 |
| Frame p95 / p99, warm passes | 11.6–12.0 / 13.3–14.8 ms | 12.4 / 14.7–14.8 ms |
| Worst event-loop stall while importing + syncing | 7,179 ms and 4,400 ms | 190 ms and 93 ms |
| Worst frame while importing + syncing | 404 ms and 411 ms | 69 ms and 76 ms |

**Pixel 8 Pro** (four photos; the large "after" run was not collected because
the phone was reassigned): warm passes went from 150 original chunk reads and
4–5 decodes per pass, with RSS rising 367→529 MiB and the image cache growing
by duplicate entries, to 0 reads, 0 decodes, 0 % placeholders, a flat 4-entry
image cache and flat RSS (327–346 MiB). Frame p95 stayed ~6 ms. Before the
change, the 300 + 700 collection rebuilt Notes in 646 ms and stalled the event
loop for up to 1,105 ms while importing and syncing.

On Windows (this reference PC, profile), `photo_scroll_test` passes (warm p95
1.1 ms, 0 reads/decodes). The `responsiveness_test` gate still fails: p95 is
12.2 ms (previously 48.7 ms raster) but one 42.5 ms raster frame exceeds the
33.3 ms p99 limit among 53 frames. It has not been weakened.

**Keep-style Notes grid, 14 September 2026** (Windows reference PC, profile,
`PERF_ENFORCE=true`, single runs): `responsiveness_test` now passes. It takes a
note in the editor while importing, filters, scrolls and clears the filter:
135 frames, frame p95 10.2 ms, p99 15.3 ms, max 29.8 ms, event-loop p95 1.2 ms.
`photo_scroll_test` (four photos) passes with 0 original reads, 0 decodes,
0 % placeholders and 0 frames over budget; warm frame p95 is 1.7–1.9 ms. The
grid packs the fixture into two columns, so each pass travels 343 px rather
than the longer single-column list. Compare frame values, not travel, with
earlier rows.

On the **Blackview BV6600 Pro** the first grid build failed the photo gate.
Generating four 12 MP previews took about 8 s. The grid shows all four at once,
and its short passes (4 gestures, 698 px, about 2.8 s) ended before generation
finished. Warm passes then still read originals (47 chunks) and showed
placeholders for up to 1.5 s. Timing on the phone showed where the time went:
- About 3 s reading and decrypting each original, because two reads
  interleaved on the serial attachment worker.
- About 0.3 s decoding.
- About 2 s encoding and storing, while still holding a generation slot.

Changes:
- `BlobWorker.readLocal` verifies and decrypts a whole stored original on a
  short-lived isolate with a read-only connection, in parallel with the worker.
  The same size, hash and authentication checks apply.
- The slot is released as soon as a preview is on screen. Stores run one at a
  time, after a pause in frames, so GPU read-back and compression stay out of
  scrolling.
- Freshly decoded previews reach the screen one frame apart.
- List previews use a 640 px edge (`list640`). Stored `list960` previews are
  still used, not regenerated.

| BV6600 Pro, four 12 MP photos | Committed list | First grid | Grid after fixes |
|---|---:|---:|---:|
| Original reads, warm passes | 0 | 47 / 13 / 0 | 0 in all passes |
| Placeholders, warm passes | 0 % | up to 1,550 ms | 0 % |
| Longest placeholder, cold pass | 450 ms | 1,750 ms | 1,200–1,500 ms |
| Frame p95, all passes | 12.2–14.0 ms | 11.9–17.0 ms | 11.1–16.2 ms |
| Frame p99, cold pass | 19.0 ms | 37.2 ms | 22.1–45.3 ms (five runs) |
| Worst event-loop stall | 57 ms | 42 ms | 34–98 ms (up to 159 ms before stores ran one at a time) |

The cold placeholder is longer than in the list because four photos wait at
once rather than one as each scrolls into view. The last enforced run passed
every gate except cold-pass p99, at 34.3 ms against a 33.3 ms limit. That pass
generates all four previews, and its p99 (the second-worst of roughly 130
frames) varies widely between runs on this phone. Assertions are unchanged.
Previews for photos imported through the app or received by sync are prepared
in the background before they are seen. This fixture writes photos directly,
so it measures the worst case.

Remaining issues: the 190 ms stall during import on the slowest phone exceeds
the 100 ms target (object publication — key agreement, signing and
self-verification — still runs on the UI isolate); first-ever preview generation
for a 12 MP photo shows a placeholder for up to ~0.6 s on that phone; and
the 512 MiB local blob quota limits how many full-size phone originals can be
stored locally, independent of scrolling performance.

## Camera-return ANR investigation, 15 September 2026

**Symptom.** After adding a photo to a note, the BV6600 Pro repeatedly showed
"not responding". Its ANR reports (`adb shell dumpsys dropbox --print
data_app_anr`) show why the warnings kept coming. Between two ANRs 12 minutes
apart, the main thread used 638 s of CPU (88%), and the process averaged 341%
CPU for 5 minutes. With Flutter's merged threading on Android, the main thread
runs the Dart UI isolate, so a busy UI isolate delays Android input.

**Cause: routine work grew with local history.** A fresh profile did not
reproduce it: adding a 12 MP photo cost ~10 s of UI-thread CPU at 25–35%, then
idled. The cost grows with history because every note change (each autosave,
the attachment operation) starts a sync with connected devices. On an 825-object
history, the phone measured:

- Offer and inventory hashed evidence for **every object on every page**, in
  both directions: 130 ms offering to an in-sync peer (87 ms stall) and 57 ms
  per inventory. A single edit plus sync took ~850 ms with 125–160 ms stalls.
- Initial or catch-up sync re-verified every object and evidence record already
  stored, and every copy of the same device certificate. Verification was 34 s
  of a 45 s PC sync, and 201 s on the phone for 825 objects.
- Handoff and receipt signatures (pure-Dart Ed25519), and one fsync per stored
  row, ran on the UI isolate.

**Changes (core, protocol and data unchanged):**

- The store keeps each object's evidence digest current as evidence is written.
  Inventory and offer compare digests and skip reconciled objects before
  parsing them.
- Received objects and evidence already stored are content-addressed and were
  verified on arrival, so only new records are sent for verification. Each
  distinct certificate is verified once per verifier isolate. Forged new
  evidence for a held object is still rejected (`security_test`).
- Handoffs for a page, and receipts for a received page, are signed together in
  a short-lived isolate on disk profiles, as publications already were.
  Receipts for items already stored are still written if a later item fails.
- Each item's writes, and each batch of evidence, commit in one transaction
  (`Store.batch`). Hot statements are compiled once. Parsed evidence is cached
  until it changes. Each record's canonical encoding is computed once.
- Home-screen widgets are not re-sent, re-encrypted and redrawn when a change
  leaves their content unchanged.

**Repeatable journey.** `integration_test/note_history_test.dart` builds
`NOTES`×`EDITS` note revisions (default 25×30, 825 objects), pairs a second
device of the same person and keeps it syncing 400 ms after changes, as
`PeerNetwork` does. It then opens a note in the full app, returns a
12 MP fixture photo "from the camera" (with pause/resume notifications), and
types through four autosaves while the photo is stored and previewed. It
verifies that the text and photo reach the other device, and reports UI-thread
CPU (Android `/proc/thread-self/stat`), frames and event-loop delay per phase.
Both nodes run on the UI isolate, so the sync cost includes the simulated peer.
The external camera and the network stack are not exercised.

```powershell
cd app
flutter drive --profile -d DEVICE_ID --driver=test_driver/performance.dart --target=integration_test/note_history_test.dart
```

`NOTE_HISTORY_BASELINE.json` records single profile runs on the BV6600 Pro,
before and after the changes:

| 825 objects, BV6600 Pro | Before | After |
|---|---:|---:|
| Initial sync: UI-thread CPU | 71.5 s | 26.6 s |
| Initial sync: wall time | 202 s | 94 s |
| Initial sync: event-loop delay p95 / max | 23 / 193 ms | 4.9 / 108 ms |
| Camera return + typing (21.6 s): UI-thread CPU | 10.5 s | 7.8 s |
| Camera return + typing: event-loop delay p99 / max | 82 / 169 ms | 26 / 74 ms |
| Camera return + typing: frame total span p99 | 113 ms | 47 ms |

A separate probe of the same history on the phone: offering to an in-sync peer
went from 130 ms (87 ms stall) to 20 ms (no stall), inventory from 57 to 12 ms,
and an edit plus sync from ~850 ms to ~270 ms (stall 125–160 → 30–50 ms).

Earlier changes in this investigation still apply: disk-profile publication
(encrypt, sign, verify, ID) and draft encryption run in short-lived isolates;
network start/stop transitions are serialized across camera pause/resume; and
the editor allows one image picker at a time and ignores results after it
closes.

Remaining: the camera-return phase still has ~10 frames over two frame budgets
(builds up to 50–80 ms) and uses about a third of a core. The initial sync still
has ~100 ms stalls. Histories much larger than 825 objects have not been
measured on the phone. Stall-free offer and inventory scale with object count
(map lookups), while initial sync scales with the number of new records. On
this phone, some `flutter drive` runs hang at first launch after install
("Flutter Driver extension is taking a long time"). Stop the app and rerun with
`--use-application-binary` pointing at the built APK. The Dart CPU profiler
connection also drops during this journey's camera phase, so function-level
profiles of that phase were not collected.

## Transport throughput baseline

Run from `transport`:

```powershell
dart run bin/benchmark.dart ../PERFORMANCE_BASELINE.json
```

The harness uses two real local iroh endpoints, separate temporary on-disk SQLite
databases, 100 encrypted messages and a 1 MiB encrypted attachment. Automatic sync
is disabled in this harness so it cannot overlap and distort the timed phases.
It validates receipt of the messages before reporting timings. The JSON captures
the platform, Dart version, timings, inventory size and process resident memory.

The checked-in baseline is a **Dart VM/JIT development run**, not a Flutter release
benchmark or an Android battery result. Both peers run in one process. RSS includes
the VM, both nodes and native libraries; it is not the memory footprint of one app.
Repeat runs on the same hardware and compare medians before drawing conclusions.
Avoid running builds alongside the benchmark when collecting comparison results.

For a compiled run (including SQLite's native asset):

```powershell
dart build cli -t bin/benchmark.dart -o build/benchmark
.\build\benchmark\bundle\bin\benchmark.exe ..\PERFORMANCE_RELEASE_BASELINE.json
```

The initial single runs on this Windows machine were:

| Measurement | Development VM | Compiled executable |
|---|---:|---:|
| Publish 100 encrypted messages | 1.68 s | 1.46 s |
| Sync 100 messages over local QUIC | 5.47 s | 6.41 s |
| Encrypt/store 1 MiB | 97 ms | 142 ms |
| Download/decrypt 1 MiB | 255 ms | 278 ms |
| Process RSS, both peers | 359 MiB | 132 MiB |

These are initial baselines, not proof of a latency improvement or a comparison
with the Rust prototype. The compiled process used less memory in this sample;
message-sync verification cost deserves profiling. Neither harness includes the
Flutter UI. Both JSON files are kept alongside this document for reproducibility.

For the actual Windows app, find its PID with `Get-Process ournet`, then:

```powershell
.\tool\measure-idle.ps1 -ProcessId 12345 -Seconds 30
```

Measure separately with networking disconnected, connected and settled, and during
a transfer. CPU is reported as a percentage of one core; memory is reported as
working set and private bytes. Keep window state and profile data comparable.
Android battery/thermal/background measurements still require physical hardware.

Development test times can be measured with `Measure-Command { .\tool\check.ps1 }`.
Package build time can be measured with `Measure-Command { .\tool\package.ps1 }`.
Separate first native builds from incremental Dart builds in comparisons.

## Conversation history journey, 16 September 2026

`integration_test/conversation_history_test.dart` uses two temporary disk profiles
and 1,005 encrypted messages. After initial sync it opens an older history page,
scrolls, then receives twelve new messages while typing. It asserts that loaded
reading position and draft are preserved, then opens the latest page and sends
the draft. Initial fixture creation and initial sync are outside the timed phase.
The two nodes share the process; the journey does not exercise a WAN connection.

`tool/check.ps1 -Performance -Device windows` now includes this journey after the
existing responsiveness, photo-scroll and note-history journeys. It uses the
same frame p95/p99 and 100 ms event-loop-delay budgets, with at least eleven
measured frames. No timing assertion was weakened.

On this Windows reference machine, all four journeys passed on the final source.
The messaging phase measured 116 frames over 2.4 seconds: frame-stage p95 8.938 ms,
p99 10.596 ms, maximum 10.752 ms, and maximum sampled event-loop delay 15.338 ms.
Report: `app/build/conversation_history_test-windows.json`. This is one profile
run, not a comparative speedup claim. No physical Android device was connected;
Android, WAN and real voice/video acceptance remain outstanding.
