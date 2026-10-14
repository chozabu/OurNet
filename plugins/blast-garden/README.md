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
