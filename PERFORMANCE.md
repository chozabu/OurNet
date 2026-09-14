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

Android profile builds use the application ID `org.ournet.ournet.profile`
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
  (longest edge 960 px, JPEG, PNG when translucent) stored in a separate
  `previews` table, sealed with the file's own key and bound to the object ID
  (AEAD associated data), bounded to 128 MiB and evicted least-recently-used.
  `ThumbnailImage` uses the object ID as a stable image-cache key, and decodes
  at display resolution, so recreated rows are served synchronously from
  Flutter's bounded image cache; after eviction only the small preview is read.
- A missing preview is generated at most twice concurrently: original read and
  decryption on the attachment worker, downsampled engine decode, immediate
  display of the decoded frame, then compression in a short-lived isolate and
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
  each item remains atomic. Sync inventories use one evidence-ID query instead
  of parsing evidence per object.
- UI lists share per-build derived data (profile names, unread objects, forum
  definitions and moderation, reply counts) instead of rescanning history per
  row. File presence is one query per file and positive results are remembered.
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
(time-sliced), and broad history processing remains for first loads.
Windows first-use rendering, large-history pagination/incremental projections, sync-under-load scenarios,
direct input-to-paint measurement, cancellation and physical Android validation
remain follow-up work. The new measurements should guide that work.

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

Remaining issues: the 190 ms stall during import on the slowest phone exceeds
the 100 ms target (object publication — key agreement, signing and
self-verification — still runs on the UI isolate); first-ever preview generation
for a 12 MP photo shows a placeholder for up to ~0.6 s on that phone; and
the 512 MiB local blob quota limits how many full-size phone originals can be
stored locally, independent of scrolling performance.

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
