# Working on OurNet

The app is Flutter; protocol/storage code is in `core`, and networking/file
transfer is in `transport`. Preserve the separation between these packages.

## Responsiveness

- Treat responsiveness separately from operation completion time. Keep typing,
  navigation and unrelated actions usable while long operations run.
- Do not introduce hashing, encryption, large decoding loops or synchronous blob
  I/O in widget build methods or UI callbacks. Use the node's attachment worker
  for blob processing, and explicitly bound concurrency and memory growth.
- Avoid broad history scans for presentation-only changes. Coalesce data updates;
  preserve loaded data, drafts and scroll state during background work.
- Provide operation-specific progress and error handling. Do not use the global
  busy state for new independent long-running actions.
- For performance-sensitive changes, run the relevant package tests and analysis.
  Run `tool/check.ps1 -Performance` on an available Windows reference machine for
  import/preview/UI changes. Use a physical device for Android timing validation.
  Report unavailable platforms and failing budgets explicitly; never weaken a
  timing assertion just to obtain a passing run.
- Lists must not read, decrypt or decode originals: show durable encrypted
  previews with stable image-cache keys (`ThumbnailImage`), and derive per-row
  data once per build (`memo`) rather than rescanning history in item builders.
- Android profile runs install as `org.ournet.ournet.profile`; never run
  measurement builds under the everyday application ID. Extend
  `integration_test/photo_scroll_test.dart` for list/image changes.
- Follow `PERFORMANCE.md` for measurement boundaries, profile-mode runs and
  baselines. Do not compare debug timings to profile/release timings or collect
  benchmark results while other builds or test suites are running.
