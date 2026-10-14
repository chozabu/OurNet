# Script plugins: design notes

Status: thinking, October 2026. Nothing built. PLUGINS.md has said since the
start that scripting should be "a WASM plugin that hosts a script engine";
this works out what that could mean here.

## Why

Today a plugin is Rust built for `wasm32-unknown-unknown` by `plugins/pack`.
That needs a Rust toolchain, a build per change, and a developer machine.
Script plugins would let:

- People who know JavaScript (or ask an assistant to write it) make plugins.
- A plugin's repository *be* the plugin: manifest, `ui.rfwtxt`, scripts. No
  build step, so the app itself can install from a repository and tag
  (see plugins/git/README.md, "Plugin development over git"), on Android too.
- Edits apply in a second: reload the script, not a component.

Rust stays the choice for anything heavy (the VPN, real-time games,
parsing packs): the script engine is slower and the bulk paths stay native.

## Shapes considered

1. **One script-host plugin that runs everyone's scripts.** Simple to ship,
   but every script would share one manifest: one set of grants, kinds and
   storage, and one publisher. That breaks the permission model. No.
2. **The engine as a shared component; each script plugin its own package.**
   A script plugin's package is a normal `.ournet-plugin`: its own manifest
   (id, grants, kinds, sections), `ui.rfwtxt`, `scripts/main.js`, and
   `plugin.wasm` = the standard engine, byte for byte the same in every
   script plugin. The host already caches compiled code by package hash
   per engine; keying that cache by the wasm's own hash would compile the
   engine once for all of them. Grants, signing, releases, sharing,
   storage and cursors all work unchanged. **Recommended.**
3. **A script engine inside the native host, beside wasmtime.** Fastest to
   call, but a second sandbox to secure and a second runtime to keep on
   every platform, which PLUGINS.md set out to avoid. No.

What shape 2 needs from the host, all additive:

- A way for the engine to read its own package's files: a new WIT interface
  (`package.read(name) -> option<list<u8>>`, always granted, package files
  only). New interfaces keep older plugins linking.
- Packaging: `plugins/pack` (and later the app) zips a script plugin without
  compiling, adding the engine from a pinned, signed release. The release
  records the engine's digest, so friends can see which engine a script runs
  on.

## The engine

The host gives plugins no WASI, so the engine must build for
`wasm32-unknown-unknown` or be given small shims.

| Engine | Language | Notes (to verify in a spike) |
|---|---|---|
| Boa | JavaScript | Pure Rust, builds for our target as is. Larger and slower than QuickJS |
| QuickJS (rquickjs / Javy) | JavaScript | Small and fast; C, normally built for WASI, so it needs a sysroot and shims here |
| Rhai | Rhai (Rust-like) | Pure Rust, small, made for embedding and sandboxing; few people know it |
| Lua (mlua) / piccolo | Lua | mlua is C (same problem as QuickJS); piccolo is pure Rust but young |

JavaScript is what most people (and assistants) write, so it should win if
size and speed are acceptable. First measurement: engine size per package,
time to start, and the cost of a call such as `ui.update` with a page of
data, against the same plugin in Rust.

## The script API

The same API as the Rust SDK, in JavaScript's shape:

```js
export function onOpen(surface, context) {
  const notes = ournet.query({ kind: "x.notes.note", limit: 50 });
  ournet.ui.update(surface, { notes: notes.map(n => n.json()) });
}
export function onEvent(surface, name, args) {
  if (name === "add") ournet.publish("x.notes.note", "x.notes", "personal", { text: args.value });
}
```

- The engine is a normal Rust plugin (shape 2) whose `Plugin` methods call
  the script's exported handlers and expose the imports as `ournet.*`.
- Imports block as they do now; scripts see them as ordinary calls, so no
  promises are needed for the first version.
- CPU and memory limits are the host's, already: a runaway script traps the
  instance like a runaway Rust plugin.
- State across hot reloads: the engine keeps `saveState`/`restore` and can
  reload just the script.

## Open questions

- Does a script plugin show its source to whoever runs it? (Easy with
  shape 2: the script is in the package. Seems right for accountability.)
- One engine version for all, or each package pins one? (Pinning is safer
  for compatibility; the cache still shares identical engines.)
- TypeScript: run through a transpile step in `pack`, or keep plain JS?
- How small can the engine get before phones care (each package carries a
  copy unless the host learns to share it)?

## A first step

A spike: the engine plugin with Boa, and `tictactoe` rewritten as a script,
measured against the Rust version (size, start time, a move's round trip).
That says whether JavaScript via Boa is good enough, or QuickJS shims are
worth it.
