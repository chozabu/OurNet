# Blast Garden

A standalone OurNet game plugin, inspired by the arena fun and teamwork of
classic bomb games. All artwork is original and drawn by the existing Canvas
API. It uses the existing sandbox and SDK, with no bundled assets, workspace
registration, WIT changes or store changes. New thumb controls use optional
Canvas input/layout support in `app/lib/ui/plugin_view.dart`; older hosts
automatically use tap controls instead.

## Play

Install `dist/blast-garden.ournet-plugin` through Settings → Plugins → Install
file. Choose Co-op rescue or Versus arena, then Play solo or invite an online
friend who also installed it. Invitations use the selected mode.

- **Co-op:** five gardens with stronger pests, faster enemies and a shielded
  final encounter. Upgrades carry between stages. Walk next to a fallen
  teammate to revive them after their flames clear. Friendly fire is enabled.
- **Versus:** four combatants. Solo has three bots; a friend replaces one bot.
  Last survivor wins. The garden closes after two minutes to prevent stalemates.
- **Controls:** arrows/WASD move; Space/Enter drops a bomb. Hold and slide the
  left thumb pad and tap the right bomb button simultaneously. Landscape places
  the controls beside the arena. Release/cancel stops at the current tile centre;
  reverse immediately or buffer a turn for the next intersection. Tap controls
  move one tile at normal speed. You can walk away from your own bomb but cannot
  walk back through it. Every bomb has a 2.4-second fuse.
- **Upgrades:** F increases range, + increases bomb capacity, > speeds movement,
  S absorbs one hit, K kicks bombs (they roll until blocked), H gives two shield
  charges, and rare M pickups give maximum flame. Shields give a short grace
  period after absorbing damage. Fuse countdowns and urgent pulsing show when
  a bomb will explode; characters and rolling bombs animate between tiles.

Friend play is currently **two human devices**, with bots filling the arena.
No online matchmaking, saved campaign, audio, mounts or four-human lobby yet.
Leaving ends the session; the host can restart or advance a cleared garden.

## Build and check

From this directory:

```powershell
cargo test -p blast-garden
cargo clippy -p blast-garden --all-targets -- -D warnings
cargo run -p pack --release
```

The nested workspace intentionally isolates this project from `plugins/Cargo.toml`.
Its source manifest is `package/manifest.json`, so the bundled plugin packer's
directory scan also ignores it.
The local packer uses the same WASM component encoder and package format as
the existing packer, and writes only `dist/blast-garden.ournet-plugin` here.
Install the Rust `wasm32-unknown-unknown` target before packaging.

From `app/` (uses the real native WASM host and Flutter renderer):

```powershell
flutter test --no-pub ../plugins/blast-garden/test/ui_test.dart
flutter test --no-pub ../plugins/blast-garden/test/network_test.dart
```

For standalone Dart analysis, copy the app's package configuration into this
directory's ignored `.dart_tool/package_config.json`, resolving relative
`rootUri` entries against `app/.dart_tool/package_config.json`, then run
`dart analyze test`. Flutter tests already use the app's package configuration.

Screenshots can be captured with
`--dart-define=BLAST_SHOTS=D:/git/OurNetAS/plugins/blast-garden/screenshots`.

## Store handoff

Use manifest ID `blast-garden`, version `0.2.0`, and the package in `dist/`.
The package is unsigned; the store's publisher/release flow should sign and
publish it. Do not add it to `app/assets/plugins` or the bundled plugin list.
The only requested grants are identity (friends/devices) and live (invitations,
inputs and arena snapshots). It publishes no objects and accesses no files,
keys, original media or history. Installation through the store remains to be
tested once the store implementation is ready.

## Multiplayer and limits

The inviter simulates smooth movement at approximately 30 Hz. Guests interpolate
positions from authoritative snapshots and send sequenced controls;
bomb presses use a cumulative counter so a dropped packet cannot lose a press
or duplicate a bomb. Snapshots contain the whole arena and stay under 600 bytes
with all 16 bomb slots occupied. Device and session checks reject unrelated
traffic; malformed snapshots are rejected before replacing state. Every
restart gets a new session to reject delayed packets from the old round.
Invitations and joining have explicit timeouts; an active match ends after
ten seconds without valid peer traffic. The host remains authoritative;
competitive play assumes you trust your friend who hosts the game.

Both friends must install version 0.2: this plugin's new snapshot format is
versioned and mismatched invitations/snapshots are refused. Core peer protocols
and their compatibility floor are unchanged.

Canvas additions are optional `onPointer` (`phase`, `pointer`, logical `x/y`),
`label`, `onActivate` (accessibility), and `onViewport` (once per viewport change).
Touch moves are coalesced per frame with a maximum eight pending pointers;
release/cancel discards pending moves. Existing tap/drag handlers remain intact.

Simulation memory is bounded: 143 cells, four combatants, 16 bombs, bounded
invitation queues, and bounded bot pathfinding. No history reads or UI-thread
game simulation. Timing and touch feel still need validation on physical Android
hardware; widget tests do not establish profile-mode performance budgets.

## Validation — 13 October 2026

### Version 0.2

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

### Initial version 0.1

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
