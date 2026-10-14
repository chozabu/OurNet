# Sharing plugins: how to, status, next steps

Phase 1 of [STORE-PLAN.md](STORE-PLAN.md) (signed releases between friends).
The format and rules are in the "Releases" section of
[PLUGINS.md](../PLUGINS.md); this file is the working notes.

## Status

- Released in 0.2.35 (Google Play internal testing, version code 412398,
  2026-10-13; not sent to the Microsoft Store). Commit `4ff4a9c`.
  `PeerNetwork.requiredCaps` unchanged.
- Verified by hand on two devices (2026-10-13): publish on the Windows
  desktop, install on a phone from "Offered to you", publish an update, take
  the update on the phone.
- Not yet tried by hand: sharing with a friend (Share with friends), a plugin
  shared privately reaching the recipient's other devices, the
  failed-start rollback.

## Where it is in the app

Settings › Plugins (`app/lib/ui/plugins_page.dart`):

- **Installed**: "by you" / "by <name>" for signed plugins; the ⋮ menu has
  **Share with friends** (picks friends; you are not in the list).
- **Offered to you** (only when non-empty): plugins friends shared, and newer
  releases from publishers of installed plugins, with **Install** or
  **Update**. The confirm dialog lists the grants.
- **Comes with OurNet**: bundled plugins (unsigned, no publisher).
- **Install from a file**: a `.ournet-plugin` package.
- **Publish a package** (Windows, Linux, macOS only): signs a package as
  yours and offers it to everyone following you.

## Publishing and updating a plugin

1. Change the plugin and raise `version` in its `manifest.json`
   (e.g. `plugins/echo/manifest.json`).
2. `cargo run -p pack --release` in `plugins/`.
3. Settings › Plugins › Publish a package, pick it from `plugins/dist`, write
   what changed.

Publishing refuses a version not after your last release, and a manifest
friends on the previous release could not exchange data with (removed kinds
or fields, changed types, tightened limits, newly required fields:
`PluginManifest.incompatibleWith`). Add new kinds or optional fields instead.

Installed devices follow the publisher's release space (`_plugins:<publisher>`)
on all the person's devices, so the update arrives on the next sync and shows
under "Offered to you". Updates are manual. If the new version fails before
`init` returns, the previous version restarts with its storage and the
release is skipped.

## Your own second device

Installs are per device; nothing installs itself elsewhere. Your other
devices see your own releases, and releases from publishers you installed
from, under "Offered to you". Unsigned plugins (bundled, from a file, the
developer folder) do not carry over: install them again, or publish once.

## Gotchas

- **Do not publish the bundled plugins under a personal key yet.** A friend's
  bundled copy has no publisher, so your release counts as another plugin of
  the same ID: installing it replaces theirs and deletes what it stored (the
  button says Install, not Update). Settle open decision 2 first.
- Windows `flutter test`: a stale `app/build/unit_test_assets` can hold a
  Vulkan-only `shaders/ink_sparkle.frag` and fail tap-heavy widget tests
  ("does not contain appropriate runtime stage data for current backend
  (SkSL)"). Delete that folder.
- Git worktrees under the long temp/scratchpad path fail the Rust link
  (LNK1104); use a short path such as `D:\onclean`.

## Tests

`core/test/plugin_release_test.dart`: package digest and refusals, signing
and verification, refusing incompatible versions, a friend installing a
shared plugin and taking updates, replacement by another publisher, refusing
live messages for another publisher's plugin. Also `plugins_test.dart`,
`vpn_plugin_test.dart`, `app/test/plugin_view_test.dart`,
`plugin_ui_test.dart`.

Still missing from phase 1's list:

- a two-node publish, fetch and update test over real `transport`;
- a recovery test that kills the process between each install step;
- an upgrade fixture with an installed signed plugin.

## Next steps

1. Try sharing with a friend, and the rollback, by hand.
2. Write the missing phase-1 tests above.
3. Settle the open decisions in STORE-PLAN.md: shared IDs as a compatibility
   promise; which key signs first-party plugins; first-party updates between
   app releases; listing default; unattended-update default.
4. Phase 2, discovery: opt-in listings of friends' plugins, the `plugins`
   interface (a store as a plugin), a first-party store (Discover,
   Installed, Updates, Details), bounded seeding.
5. Phase 3, updates: opt-in unattended updates, the recipient compatibility
   check, roll back on request, withdrawals and warnings.
6. Phase 4: catalogs, friends' reviews, channels, publisher transfer,
   reproducible builds.
7. Before first-party plugins update outside app releases, check Play and
   Microsoft Store policy (STORE-PLAN.md "Platform policy").
