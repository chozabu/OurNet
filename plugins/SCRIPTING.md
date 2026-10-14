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

| | Isolation per script | Engine stored | Engine updates | Host work |
|---|---|---|---|---|
| A. Engine copied into each script's package | Yes: own instance, grants, storage, publisher | Once per package (MBs each) | Every script re-released | Small: read own files |
| B. One plugin per language runs many scripts | No: one instance, one set of grants and storage; one script's crash stops all | Once | Once | None, but the plugin must re-implement permissions |
| C. The core runs scripts itself | Yes, if built so | Once, in the app | Only with app releases | Large: a second sandbox, per platform; languages fixed by the app |
| **D. Runtime plugins** | Yes, as A | Once | Once | Medium |

**D (recommended, October 2026).** A language runtime is a plugin package
of its own, marked as a runtime (`"provides": "runtime:js@1"`), carrying
only the engine. A script plugin's manifest names the runtime it needs
(`"runtime": "js@1"`) and ships only its manifest, UI and scripts. The host
starts *one instance of the runtime per script plugin*, with that plugin's
grants, kinds, storage, cursors and publisher, exactly as if the engine were
in its package; the runtime reads the scripts through an always-granted
interface that sees only that package's files. So:

- Each script is sandboxed and accountable on its own, as with A.
- The engine is downloaded, stored and compiled once (the compile cache is
  keyed by the component), and an engine fix reaches every script at once.
- New languages are plugins: anyone can publish a `runtime:lua@1`, and
  nothing in the app changes.

What it costs:

- Host: the manifest fields, resolving a script plugin's runtime (installed,
  or fetched like any offered plugin), and starting the runtime's component
  for it. The WIT additions are additive.
- Trust: a runtime's code runs with each script's grants, so the install
  prompt names it ("runs on JavaScript by <publisher>"). Bundled runtimes
  come from us; a third-party runtime is a choice the person makes once.
- Versions: a script pins a runtime's major version; minor updates must stay
  compatible, as the WIT world does.

B stays possible later as a "playground" for trying snippets with no grants
at all. A is how D degrades if a friend cannot get the runtime (rare, since
runtimes travel like plugins).

What D needs from the host, all additive:

- A way for the engine to read its script plugin's files: a new WIT
  interface (`package.read(name) -> option<list<u8>>`, always granted).
- Manifest fields `provides` and `runtime`, refused by older builds (which
  cannot run them anyway).
- Packaging: `plugins/pack` (and later the app) zips a script plugin with no
  compile step.

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

- The runtime is a normal Rust plugin whose `Plugin` methods call
  the script's exported handlers and expose the imports as `ournet.*`.
- Imports block as they do now; scripts see them as ordinary calls, so no
  promises are needed for the first version.
- CPU and memory limits are the host's, already: a runaway script traps the
  instance like a runaway Rust plugin.
- State across hot reloads: the engine keeps `saveState`/`restore` and can
  reload just the script.

## Decided (Alex, 14 October 2026)

- **JavaScript first.** Other languages come later, as runtimes anyone can
  publish.
- **Engine: Boa first** (pure Rust, builds for our target as is). Move to
  QuickJS only if the spike shows Boa is too big or slow.
- **Runtimes are regular plugins:** packaged, signed, released, shared and
  updated like any other, marked by `provides`, with no grants or pages of
  their own. Anyone can publish one; installing a script plugin names the
  runtime and its publisher.
- **Async is optional.** Plain calls block, as the host's imports do today;
  calls whose answer comes later (`live.send`, timers) can also be awaited as
  promises, which the runtime resolves from the matching `on-reply` or
  `on-timer`. A script that never uses `await` never needs to.
- **Source is visible:** the app shows a script plugin's scripts to the
  people running it.
- **Spike:** tictactoe and pong as scripts, measured against their Rust
  versions (package size, start time, a move's or a frame's round trip).

## Open questions

- TypeScript: run through a transpile step in `pack`, or keep plain JS?
- How small can the engine get before phones care?

## A first step

A spike: a JavaScript runtime with Boa (first as shape A, which needs no host change), and `tictactoe` rewritten as a script,
measured against the Rust version (size, start time, a move's round trip).
That says whether JavaScript via Boa is good enough, or QuickJS shims are
worth it.
