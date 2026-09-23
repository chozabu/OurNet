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
- Work that runs on every change (sync, refreshes, widgets) must cost the
  same on a long history as on a new profile: keep incremental state instead of
  rescanning, and never re-verify or re-hash stored records. Extend
  `integration_test/note_history_test.dart` for sync and editor changes.
- Android profile runs install as `org.chozabu.ournet.profile`; never run
  measurement builds under the everyday application ID. Extend
  `integration_test/photo_scroll_test.dart` for list/image changes.
- Tester builds go to Google Play internal testing via
  `tool/release-android.ps1 -Notes "..."`. The upload keystore and Play service
  account key live in `%USERPROFILE%\.ournet-signing`, never in the repo.
- Follow `PERFORMANCE.md` for measurement boundaries, profile-mode runs and
  baselines. Do not compare debug timings to profile/release timings or collect
  benchmark results while other builds or test suites are running.

## Compatibility

Store rollouts are staged, so friends run mixed versions for days. Change the
protocol and database additively: new optional fields, kinds and request types
that older builds ignore or refuse individually. Never change the meaning of an
existing field or kind. A breaking change needs a new ALPN that the next release
accepts alongside `ournet/2`. Peers exchange `version` (keep `appVersion` in
`app/lib/build_info.dart` equal to `pubspec.yaml`, which a test checks).
When releasing a new version, run `dart run tool/upgrade_fixture.dart <version>`
in `core` and commit the saved profile; `test/upgrade_test.dart` opens every
saved profile with the current build.

## Microsoft Store

- Store releases go through `tool/publish-store.ps1 -Build` (builds the Store
  MSIX with the Partner Center identity, then uploads and submits it with the
  `msstore` CLI). Bump the x.y.z part of `version:` in `app/pubspec.yaml` first:
  the Store needs a higher version for every submission.
- Store API credentials live in `%USERPROFILE%\.ournet-signing\msstore.json`,
  never in the repo. The first submission of a product must be done by hand in
  Partner Center; the CLI only updates after that.
- Listing copy, age-rating answers and certification notes are in
  `store/microsoft-store.md`; `store/submitted-version.txt` is the last version
  the Store has.
