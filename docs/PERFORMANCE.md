# Repeatable performance checks

## VPN latency

`transport/bin/latency_benchmark.dart` runs two temporary peers through real
local QUIC and the shipped VPN plugin. It measures request RTT, cold datagram
setup, warm 4-byte and 1,000-byte datagram RTT, and 1,000-byte VPN packet RTT
both idle and during synthetic datagram traffic. Each reply carries a sequence
number; missing replies fail the run rather than silently biasing the samples.
The VPN uses memory interfaces and a synthetic echo at the remote interface.
No personal profile, administrator access or system VPN adapter is used.

Build from the repository root, then run from `transport` after builds/tests
have stopped:

```powershell
.\tool\with-native-profile.ps1 -Command {
  Push-Location transport
  try { dart build cli -t bin/latency_benchmark.dart -o build/latency }
  finally { Pop-Location }
}
Copy-Item app/native/irohdart_ffi.dll transport/build/latency/bundle/bin/
cd transport
.\build\latency\bundle\bin\latency_benchmark.exe build/latency-local.json
```

Use the current `app/native` networking library (built by
`tool/build-iroh.ps1`), not a stale DLL from an old Flutter build directory.
The first socket discovery is outside the timed phases. Cold datagram setup
is one sample after the ordinary request connection is already warm; it is
not a cold app start. Warm phases use 100 replies and the load phase 1,000.
The load generator attempts eight 1,000-byte datagrams per timer tick; actual
timer cadence is platform-dependent, so the report records the accepted packet
count rather than claiming a fixed offered rate. Accepted does not mean delivered.

The checked-in `VPN_LATENCY_BASELINE.json` is a Windows AOT/release-native
local baseline from 20 October 2026. It excludes Flutter frames, system adapter
and helper overhead, WAN paths, relays and Android. Do not interpret it as
internet latency or compare it to development VM timings. A cross-device run
should compare device ping, VPN datagram checks and system ping on the same
path, idle and under load; physical Android timing remains unvalidated.

This measurement uncovered a cold-datagram completion bug: returning
`_datagramDials.remove(device)` from `whenComplete` returned the very future
being completed, leaving its waiters stuck. The cleanup now returns void.
Waiting datagrams are also bounded across peers to 64 packets / 64 KiB;
overload drops unreliable traffic instead of accumulating a late burst.
There is no numerical before/after speedup claim: the previous cold-send path
did not complete. These changes preserve the wire protocol and plugin packages.

Saved run (milliseconds, round trip):

| Measurement | Median | p95 |
|---|---:|---:|
| Ordinary request | 0.517 | 0.718 |
| Warm 1,000-byte datagram | 0.253 | 0.335 |
| Warm 1,000-byte VPN packet | 0.434 | 0.590 |
| VPN during synthetic traffic | 0.511 | 0.862 |

Cold datagram setup and echo took 2.416 ms (one sample). The short load phase
accepted 384 background packets; it is not a saturation or sustained throughput
test. The memory-interface path adds extra Dart callbacks for the synthetic
system echo, so subtracting its RTT from plain datagram RTT does not isolate
WASM or bridge cost. These local results do not justify a native forwarding
rewrite or permanent keepalives without measurements on real device paths.

Validation: transport analysis was clean. The full transport run had 106 passes,
three opt-in skips and one direct-path event assertion failure
(`peer_path_test.dart`, path still null). The focused rerun passed all eight
backlog/path tests, including blocking a peer during a dial; both existing core
VPN plugin tests passed. No Flutter UI or physical Android timing was collected.

### Call startup, typing hints and bulk traffic, 20 October 2026

Outgoing one-to-one calls ring all of a person's devices. Previously candidate
signalling waited for every offer request to finish, so a reachable device
waited behind another device's connection timeout. Each acknowledged offer now
releases signalling to that device immediately. Pending/unreached devices do
not receive trickled candidates until their offer is acknowledged; when they
are reached they receive the candidates collected so far. An answer arriving
before the offer acknowledgement also releases queued candidates, and late
acknowledgements cannot reset a call that has already been answered.

Deterministic call tests hold one device's offer acknowledgement open and assert
that the other device receives candidates and can answer before it is released.
They also cover candidate replay to a later acknowledgement and an answer
arriving before acknowledgement. These establish removal of the wait, not an
end-to-end WebRTC media-start speedup on real hardware.

Typing hints now allow one outstanding request per device and eight across all
devices. New bursts skip pending destinations rather than starting overlapping
connection attempts. There is no replay queue for stale hints. Tests cover both
the per-device limit and the global bound, and verify fresh hints can be sent
after a pending request finishes.

The latency harness also runs two bounded workers repeatedly fetching the real
encrypted attachment `blobs` responses for a temporary 1 MiB file. Publication
and metadata sync happen before measurement; the first complete batch confirms
the load path is working. This exercises chunk serving and network contention,
not the receiving file's disk writes/decryption or a complete user download.
`TRAFFIC_LATENCY_BASELINE.json` records one Windows AOT/release-native local run:

| Round trip | Idle median / p95 | During bulk median / p95 |
|---|---:|---:|
| Ordinary request | 0.515 / 0.682 ms | 3.507 / 6.093 ms |
| 1,000-byte VPN packet | 0.432 / 0.523 ms | 0.891 / 2.165 ms |

The workers completed 55 batches (57,684,440 encrypted bytes) across the two
measured phases. This is short, same-machine contention, not WAN saturation,
relay performance or an Android/UI responsiveness result. Requests slowed under
bulk load but remained within milliseconds on this machine; no transfer
scheduler, permanent keepalive or native forwarding rewrite was introduced.
Cross-device/direct-versus-relay and physical media-start measurements remain
outstanding. App and transport analysis were clean; all 58 focused call,
group-call/UI, call-history and typing tests passed.

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

`check.ps1 -Performance` compiles `integration_test/performance_test.dart` once
for all six journeys, then saves the combined report as
`app/build/performance_test-DEVICE.json`. Each journey retains its report key,
temporary profiles and acceptance budgets. The photo decode-counting binding is
shared, and image caches are cleared between tests. Individual test targets
remain available for investigation. These checks are an explicit validation
step; `release-all.ps1` does not run them automatically.

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

This suite also runs `map_places_journey.dart`: 600 saved pins backed by
2,400 versions, saved-list scrolling, clustered-map panning, and note typing
while 12 map updates arrive. Scrolling and panning must read zero map records;
updates may read only the arriving records. It uses the same frame and
event-loop budgets, and reports `savedPlacesHistory` separately from photos.

15 October 2026, Windows reference PC, profile, 60 Hz, one run:
`MAPS_PERFORMANCE_BASELINE.json` records the saved-map journey. Saved opened
in 1,752 ms. Slower-stage p95/p99 were 1.96/2.25 ms scrolling,
3.92/5.64 ms panning, and 5.84/12.00 ms typing during updates. Worst event-loop
delays were 2.72, 6.04 and 16.98 ms respectively. All enforced gates passed.
There was one 37.81 ms raster outlier during panning. Scrolling and panning
read zero map records; incoming updates read exactly 12. The map was offline
without cached vector tiles, so these numbers cover saved-marker interaction,
not populated-tile rendering or downloading. Android timing is unvalidated.

Validation caveats: `tool/check.ps1 -Performance` stopped at the existing
`core/test/format_test.dart` assertions that omit the `_listing` subscription
already added by `Node`. The profile photo/map suite was therefore run
directly with `PERF_ENFORCE=true` and passed. The full app suite had one
location reconnect-test failure; its isolated rerun passed. Affected core
suites and transport tests passed, and package analysis was clean. Other
profile suites were not rerun after the preflight failure.

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
  usage maintained by trigger exactly as blob usage is. Since October 2026
  that is the storage limit on objects and files together (`storageLimit`,
  20 GiB by default), and own writes are never refused by it.
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
- Cursor-capable sync seeks on `(created,id)` indexes, reading at most 2,001
  routes per inventory even when none are shareable. Older pages resume from
  retained cursors; they do not reread the newer prefix. Exact ID boundaries
  also bound pages whose creation timestamps tie. Numbered-window fallback
  remains for older peers. This bounds each inventory, not the total work to
  reconcile an entire history or answer a peer with a much larger time range.
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
remain follow-up work. Sparse-sharing inventory scans are now bounded for
cursor-capable peers; full reconciliation still visits the historical pages.

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

## Group chat journey, 1 October 2026

`integration_test/group_history_test.dart` is the group counterpart: two disk
profiles and a private group holding 1,005 messages. A group chat shows
`RoomFeed`'s window (newest first, 40 or more entries at a time) instead of
reading the whole group, so the journey measures the open, then a deliberately
harsh read-back (jumping to the end of the list repeatedly until message 0 is
loaded), then twelve incoming messages while typing with the reader scrolled
away from the newest. It asserts the draft survives and that "latest" returns to
the newest message. It is part of `tool/check.ps1 -Performance`.

On this Windows reference machine (profile, one run): the chat showed the newest
message 58 ms after the group was tapped. The enforced phase, incoming messages
while typing, measured 255 frames over 2.3 seconds: frame-stage p95 7.16 ms, p99
19.4 ms, maximum 22.1 ms, and maximum sampled event-loop delay 22.1 ms. The
read-back phase is recorded but **not** asserted: it had 18 of 281 frames over
budget (build p95 38.8 ms, maximum 51 ms) because each page of earlier messages
is built in one frame after a jump to the end; it is not a figure for normal
scrolling. No physical Android device was connected; Android timing is
unvalidated. The other four journeys were not re-run for this change.

## Calendar journey, 2 October 2026

`integration_test/calendar_history_test.dart` opens the Calendar screen over two
disk profiles holding 3,000 events (about eight years, 120 of them in a shared
group, 30 repeating), then pages forward and back through 30 weeks, switches
between month, year, schedule and week views, and finally opens the new-event
form and types while a friend adds twelve events to the group. It asserts the
draft survives. It is part of `tool/check.ps1 -Performance`.

Reading is incremental (an insertion cursor into `cal_event` objects) and the
calendar is laid out once per change, outside a frame (`Calendar.warm`): the
first run of this journey, before that, had a 714 ms frame when the first
query laid out 3,000 events, and 50 ms per week of paging because every event's
time was rebuilt on each query. Both were fixed by working times out once per
event and by skipping repeating series that ended before the time shown.

On this Windows reference machine (profile, one run, enforced budgets of one
frame at p95 and two at p99, 100 ms event-loop delay): the calendar showed
today's week 280 ms after it was opened. Paging: 436 frames, frame-stage p95
11.5 ms, p99 15.3 ms, maximum 16.6 ms, none over budget; maximum event-loop
delay 23 ms. Switching views: 524 frames, p95 2.6 ms, p99 13.9 ms, maximum 75.7
ms (the year view, which expands every repeating series for the year), five
over budget. Typing while events arrived: 337 frames, p95 10.4 ms, p99 15.8 ms,
one over budget, maximum event-loop delay 21.9 ms. Report:
`app/build/calendar_history_test-windows.json`. No physical Android device was
connected; Android timing is unvalidated. The other journeys were not re-run
for this change.

## Git plugin 0.3 validation, 22 October 2026

Git transfers now spool the sending pack to a temporary file and stream through
transport's encrypted chunk-tree file storage instead of the whole-file guest
API. Repositories have synced logical deletion, local index repair, incremental
reference/status caches, individual persisted push records and cached history
pages. The guest still limits whole-pack browsing to 16 MiB; larger packs can be
pushed/cloned and report that browsing limitation explicitly. These changes do
not establish a Git throughput or frame-time baseline.

Validation on Windows: analysis of core/transport/app was clean; 440 core, 108
transport and 286 app tests passed (nine opt-in/platform skips in total), plus
nine Git Rust tests. Regression coverage includes a 17 MiB pack pushed/cloned
with real Git, a push with 131 refs, branch filtering, deletion/recreation across
restart, index repair and rendered Git code/file/commit/activity/settings pages.
The Git plugin package was rebuilt and copied to app assets and the core fixture;
the desktop helper was rebuilt. No store release was made.

`tool/check.ps1 -Performance` used the release-native wrapper and completed its
Windows profile run, but **failed calendar acceptance**. The other profile test
stages passed. An isolated calendar rerun with the same assertions also failed.
This is an unresolved acceptance failure, not a passing performance validation.
The calendar test uses 3,000 events, takes 12 incoming events and runs with
`enablePlatform: false`; it does not exercise the Git plugin. No unchanged-checkout
baseline was collected, so these results do not establish causality.

At 60 Hz the enforced limits were frame-stage p95 < 16.667 ms, p99 < 33.333 ms
and maximum event-loop delay < 100 ms. No timing assertion was changed.

| Run / calendar phase | Frame p95 ms | Frame p99 ms | Maximum loop delay ms |
| --- | ---: | ---: | ---: |
| Full suite / paging | 21.415 | 27.796 | 30.495 |
| Full suite / views | 11.377 | 40.960 | 95.325 |
| Full suite / typing | 18.151 | 21.569 | 24.041 |
| Isolated / paging | 114.319 | 443.180 | 163.180 |
| Isolated / views | 62.859 | 530.515 | 573.969 |
| Isolated / typing | 83.380 | 98.753 | 144.911 |

Both runs also warned that the calendar's Year-view tap missed its hit target.
Reports are in `app/build/performance_test-windows.json` and
`app/build/performance-calendar-rerun-windows.json`; console logs are
`build/git-upgrade-check.log` and `build/git-upgrade-calendar-rerun.log`.
The wrapper restored `native-dev` after both runs. Physical Android timing was
not available. Issues/pull requests, helper bundling and range-based browsing of
large packs remain future work.

Follow-up: the Git URL is a read-only native selectable control with an explicit
Copy button, and the clone command has a separate Copy button. App analysis and
the targeted Git UI regression (including exact clipboard payloads) passed after
this change. The existing calendar failures remain unchanged; no performance
budget was relaxed.

### Git 0.4 range/index follow-up

The earlier 16 MiB whole-pack browser budget is removed. The Git guest now reads
64 KiB windows, hashes raw blobs through a fixed inflate dictionary, writes
bounded object-index batches to a dedicated disk worker and looks up locations
on demand. Offsets are 64-bit. Branch-picker rows and helper ref metadata are
paged/batched, and common local Git checks use batch subprocesses. Index progress
is operation-specific, with restart checkpoints at completed object boundaries.

A real-checkout integration imported the approximately 22 MB OurNet pack, showed
its app/core/transport/plugins directories and commit history, rebuilt its local
index and reopened it after a host restart. This passed. Encrypted range tests
crossed data/list-chunk boundaries in a deep tree. A persisted index beyond the
old 16 MiB quota also passed. These functional checks are not kernel/Unreal-scale
performance evidence. Remaining limits and qualification targets are recorded
in `plugins/git/LIMITS.md`; in particular decoded-object previews, push/ref
metadata, LFS and SHA-256 still require work. The calendar failures above are
not cleared by these tests.

The opt-in disk-index scale test also passed: one million locations written in
bounded batches, persisted, reopened and sampled. This validates the derived
index backend; it does not qualify million-object Git imports or browsing.

The complete 0.4 check passed core (443), transport (109) and app (286) tests,
with clean analysis. Rust Git/helper tests passed (15 and 1). The Windows
profile suite still failed the calendar frame-stage p95 gate: 23.969 ms against
16.667 ms. Reports are `app/build/performance_test-windows.json` and
`build/git-range-check.log`. Budgets remain unchanged; physical Android timing
was not available. The native profile wrapper restored `native-dev`.
### Git collaboration/browser 0.5 qualification (25 October 2026)

`tool/check.ps1 -Performance` passed core (451), transport (110) and app (298)
tests with clean analysis. Rust Git tests passed (17). The real-Git integration
covers fork/clone/push, pause/restart/resume, pinned PR review and diff, merge
publication, network traversal, PR state after restart, and cloning the fork
after upstream deletion. Browser tests cover phone/desktop widths, syntax/text
preservation, search, immutable line locations, and graph node selection.

The new Windows profile journey uses 10,000 code lines and a 128-node graph
window. It passes the existing p95/p99 frame and event-loop budgets: opening/
typing, code scrolling and network panning have frame-stage p95 values of
3.786/5.199/2.490 ms and p99 values of 18.504/6.309/3.145 ms respectively.
This qualifies the bounded UI window, not arbitrary kernel/Unreal fork networks.
The complete performance suite still fails the calendar frame-stage p95 gate
(18.752 ms against 16.667 ms). Reports: `build/git-workflow-final-check.log` and
`app/build/performance_test-windows.json`. No timing assertion was relaxed.
Physical Android timing was not available. The wrapper restored `native-dev`.

Earlier checks found a transport direct-path assertion returning null under
parallel load; its isolated rerun and full 110-test rerun passed. They also
exposed the existing reminder-label DST bug on the clock-change date: date
arithmetic now constructs adjacent calendar dates, with March/October coverage.
The fork pause regression exposed timer starvation in the native plugin host;
it now returns to the call queue after each timer callback. The paused-copy
restart test passes with that fix.


### Git interface polish (25 October 2026)

Git 0.5.1 keeps the existing Material theme while separating the request list,
conversation and creation form. The real-host widget regression covers URL and
clone-command copying, rejected creation with retained drafts, expandable commit
details, and a 390-pixel phone viewport. Desktop and phone captures are in
`build/git-polish-shots`; `build/git-polish-final-ui.log` passes.

`tool/check.ps1 -Performance` completed analysis cleanly and passed 451 core,
110 transport and 298 app tests. Its Windows Git journey passes existing gates:
frame-stage p95 is 3.768 ms opening/typing, 5.144 ms scrolling code and 2.445 ms
panning the network (10,000 source lines and 128 graph commits). The full suite
still fails the calendar p95 gate, 20.413 ms against 16.667 ms; no budget changed.
Report: `build/git-polish-final-check.log` and
`app/build/performance_test-windows.json`. Physical Android timing remains
unavailable. The native profile wrapper restored `native-dev`.
