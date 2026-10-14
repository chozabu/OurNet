# Validation — 13 October 2026

## Version 0.2

- Dart analysis of the host Canvas file and standalone test folder: no issues.
- Eleven Rust simulation tests pass, including continuous motion, reversal,
  release/corner collision, damage at the nearest tile, rolling bomb collisions,
  upgrades and unchanged real-time fuse duration.
- Rust Clippy passes with warnings denied. The environment sometimes emits a
  filesystem warning about copying incremental artifacts instead of hard links.
- Nineteen Flutter tests pass: the standalone interface, real packaged game at
  three screen sizes, simultaneous two-finger movement/bombing, cancellation
  after a queued drag, rotation, fallback controls, both multiplayer modes with
  packet loss/restarts, and existing first-party plugin parsing/rendering.
- Screenshots were regenerated from the real package. Canvas text now uses
  the app's theme font.
- The package remains unbundled. `package/manifest.json` keeps the bundled
  packer's source scan from attempting to build the separate Cargo workspace.
- The only host source change is optional Canvas support in
  `app/lib/ui/plugin_view.dart`: bounded/coalesced pointer events, accessibility
  labels/actions, and viewport notification. No WIT, peer capability, store
  source, shared workspace registration or bundled asset changes.
- `tool/check.ps1 -Performance` was attempted again. Core analysis passed;
  353 core tests passed, one skipped, and the same two database subscription
  tests failed on the store's `_listing` subscription. The script stopped
  before app/transport checks or profile performance measurements. Timing
  budgets were not changed.
- Device discovery found Windows, Chrome and Edge; no physical Android device
  was connected. Android timing/feel and actual store installation remain
  unverified. Debug widget tests do not establish profile-mode timing budgets.

## Initial version 0.1

- `cargo test -p blast-garden`: six simulation tests pass.
- `cargo clippy -p blast-garden --all-targets -- -D warnings`: passes.
- Dart analysis of the isolated test folder with the app's resolved package
  configuration: no issues.
- Flutter real-host tests: interface parsing; 800×600, 360×640 and 640×360
  layouts in both modes; two networked WASM hosts in co-op and versus with
  every third datagram dropped; a dropped bomb press is eventually applied
  exactly once; restarts reject the previous session's packets; leave ends
  the remote match. Six tests pass.
- Packaged component validates during encoding. The installable archive is
  approximately 75 KiB. No bundled app assets were changed.

The Flutter batch launcher could not start in the restricted environment.
Tests ran through the installed Flutter tool snapshot with SDK-cache access,
`--no-pub --no-test-assets`, and analytics suppressed. Asset rebuilding failed
on unrelated Material shader output; this game has no asset dependency. The
test app uses InkRipple instead of InkSparkle to avoid the incompatible cached
shader. The production plugin does not change the host's theme or splash.

`tool/check.ps1 -Performance` was attempted using the installed SDK runners.
Core analysis passed. Core tests finished with 352 passed, one skipped and two
failures in `test/format_test.dart`: “a version 1 database is migrated and keeps
its settings” and “a new profile starts on general, and can leave it”. They
expect subscription sets without the concurrently added `_listing` store
subscription. The script stopped at those failures, so transport/app checks
and Windows profile performance gates were not reached. No performance budgets
were changed and no debug timings are presented as profile results.

Not yet validated: physical Android timing/input feel, real-network latency,
store signing/publishing/install flow, or a full five-stage human playthrough.
The supplied screenshots are real Flutter renders of the packaged WASM plugin,
not mockups.

One network-test attempt hit a Windows access denial while renaming a temporary
installation directory. An immediate rerun passed both modes, including the
stronger exactly-once bomb assertion.
