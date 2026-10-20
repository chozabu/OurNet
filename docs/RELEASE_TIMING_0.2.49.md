# Release timing: 0.2.49 — 20 October 2026

Build source: `9a55a1682d33e6d9dd3aee0571e5a31b128dffbb` on main.
Both builds use the same source and actual fat-LTO native release profile.

| Build stage | Cold caches | Cached repeat |
|---|---:|---:|
| Android AAB | 24m03s | 4m35s |
| Windows ZIP and Store MSIX | ~11m32s | 2m22s |
| Total, sequential | ~35m39s | 6m57s |

The cold Windows run spanned overnight sleep: Windows recorded 7h56m56s
between sleep and wake. Its raw elapsed time was 8h08m27s; the table subtracts
that suspension, so cold Windows and total are estimates. The cached repeat
was uninterrupted. This is a cold-versus-cached comparison, not an isolated
before/after measurement of the script changes.

## What matters

- Cold Android native compilation took 6m10s (ARMv7), 7m02s (ARM64), and
  8m31s (x64). A separate cold Windows native compile took 9m36s; its next
  cached invocation took 0.6s. Preserve the main checkout and native caches.
- The Dart hook runner stripped the old profile environment variable, silently
  selecting `native-dev`. Release scripts now select fat LTO through a tracked
  hook dependency and restore the previous profile even on failure. This
  corrects release configuration; it does not lower optimization for speed.
- The cached Windows run spent 11s on iroh preparation, 0.625s on its source
  snapshot, 102s in Flutter compilation, and roughly 6s on the portable ZIP.
  Incremental source mirroring preserves the staged native caches.
- After publishing, the six Windows performance entry points were combined.
  The previous run spent 11m44s compiling six applications and about 2m25s
  testing (~14m09s). The combined run took **4m16s**, including **1m45s**
  compiling and **2m22s** testing: about **9m53s saved**. This comparison spans
  the native-profile fix described above. All seven non-calendar tests passed;
  calendar retained its existing failure (20.678ms p95). All eight report keys
  were preserved, including failed calendar measurements, and the loaded DLL
  matched the fat-LTO Cargo output. Individual entry points remain available.
  This changes validation only; it does not require another store release.

## Publication

Android version code `422060` was released to Play internal testing.
Final Windows package: `OurNet-0.2.49-20261020-104505-windows.msix`.
Microsoft accepted the submission commit for version `0.2.49.0`; the last
reported state was `PreProcessing`, before certification/public availability.

| Publication stage | Elapsed |
|---|---:|
| Play upload and internal rollout | 3m45s |
| Microsoft upload and submission processing | 5m51s |
| Both stores, sequential | 9m36s |
| Cached builds plus publication | 16m33s |

Microsoft's upload completed about 2m09s into its stage; the remaining time
was submission commit/processing. There is no measured previous deployment
baseline, and remote store processing times vary.

## Validation and limits

Core: 435 tests passed. App: 280 passed, four skipped, including Linux-only
vault tests on Windows. Transport: 105 passed in the first full run; a later
peer-path count assertion failed, then all five tests in that file passed in
isolation. Package analysis passed. Actual fat-LTO native validation passed
all six core crypto parity tests and all nine native tests. Deterministic
location reconnect and sharing-level race regressions pass.

The original five passing Windows performance journeys used `native-dev`;
the subsequent combined run verified all five with fat LTO. Calendar paging
failed repeatedly with verified fat LTO: p95 **20.705ms** standalone and
**20.678ms** combined, against **16.667ms**. A Year-selection missed-tap warning
also remains. Budgets were not changed. No physical Android device was attached,
so Android UI performance was not measured.

Both final artifacts were checked against their Cargo release libraries
(after Android's normal stripping). The Android signature and Windows Store
identity/version were verified. Detailed timestamped logs, hashes, and JSON
measurements are retained locally under `build/release-0.2.49-*`.
Investigation and validation time are separate from the build table.
