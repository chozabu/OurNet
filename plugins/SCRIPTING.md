# Script plugins: design notes

Status: shape D built with a JavaScript runtime on Boa (14 October 2026):
the `js` runtime plugin (`plugins/js`), the host's side (`package-files`,
runtimes, grants held per call), the app's (installing, starting, the
install prompt, reading scripts) and two script plugins, `js-tictactoe` and
`js-pong`, measured against their Rust versions. "Built" and "Measured" say
what exists; the design notes that led there follow them.

## Built

- **Runtime** (`plugins/js`): a Rust plugin whose manifest says
  `"provides": "runtime:js@1"`. It reads the script plugin's `manifest.json`
  and `main` (default `scripts/main.js`) through `package-files`, runs it as
  an ES module on Boa 0.22 (modules import each other within `scripts/`),
  and calls the handlers it exports. `ournet` is written mostly in JavaScript
  (`js/src/prelude.js`) over a few native functions. Boa builds for our
  target with two shims: its clock comes from the host (`clock.now`), and the
  random bytes it asks `getrandom` for (Math.random) come from splitmix64
  seeded by the clock (`plugins/.cargo/config.toml` picks the custom
  backend). Not for keys; plugins never hold any.
- **Script plugin**: `manifest.json` with `"runtime": "js@1"` (and optionally
  `"main"`), `ui.rfwtxt`, `scripts/**` and `assets/`, and no `plugin.wasm`.
  `cargo run -p pack --release` zips one without building anything.
- **Host** (`native/rust/src/plugin.rs`): a `package-files` interface (always
  granted; reads the unpacked package Dart names as `package`, with no way
  out of it). `runtime: true` in the load config lets a component import
  every grantable interface, and every import now checks its grant when
  called (`Host::granted`), for all plugins. A `package` call moves
  `package-files` before a hot reload; a `usage` call returns the CPU time a
  plugin's calls have used (`Plugins.usage`).
- **App** (`core/lib/src/plugins.dart`, `plugin_manifest.dart`,
  `app/lib/ui/plugins_page.dart`): manifests take `provides`, `runtime` and
  `main`. A runtime takes no grants, kinds or sections and never starts by
  itself. A script plugin starts the runtime's component with its own
  grants, storage, cursors and package, and fails with "It needs the js@1
  runtime" while none is installed. Installing, updating, switching off or
  removing a runtime restarts or stops its scripts. Releases carry `runtime`
  and `provides`, so the install prompt names the runtime and its publisher,
  or says it comes with OurNet and installs it alongside. Settings ›
  Plugins › Read its scripts shows the source. Older builds refuse a script
  package (no `plugin.wasm`) and fail a runtime (it imports `package-files`).
- **Bundled**: the runtime only (`app/assets/plugins/js.ournet-plugin`). The
  two script plugins are examples in `plugins/` and test fixtures, not
  shipped, since they duplicate the Rust games.
- **Tests**: `core/test/script_plugin_test.dart` (runtime missing then
  installed, grants refused per call, errors logged, promises from timers,
  imports between scripts, package files, a syntax error, a real game).

### The script API

```js
// scripts/main.js
let me;
export function init() { me = ournet.me(); }
export function onOpen(surface, context) {          // context: {scope, space, name}
  const notes = ournet.query({ kind: "x.notes.note", limit: 50 });
  ournet.ui.update(surface, { notes: notes.map((n) => n.data) });
}
export function onEvent(surface, name, args) {
  if (name === "add") ournet.publish("x.notes.note", "x.notes", "personal", { text: args.value });
}
export function onObjects(objects) {}  // {id, author, device, kind, name, space, audience, created, payload, data}
export function onRequest(device, bytes) { return { ok: true }; }  // Uint8Array, text or JSON back
export function onDatagram(device, bytes) {}
export function onTimer(token) {}
export function saveState() { return {}; }  // hot reload, as JSON
export function restore(state) {}
```

- Plain calls block, as in Rust: `publish` (audience `"personal"`,
  `"group"`, `"public"` or a list of people), `get`, `query`, `follow`, `me`,
  `thisDevice`, `contacts`, `groups`, `datagram`, `storage.*` (text,
  `getBytes`, `getJSON`/`setJSON`), `ui.update`, `ui.notify`, `read` (a
  package file), `tun.*`, `log`/`warn`/`error` and `console`.
- Async is optional: `ournet.send(device, data)` returns a promise of the
  reply's bytes (`ournet.text` and `ournet.json` read them) carrying its
  `id`, and `onReply(id, bytes, error)` is called as well; `ournet.sleep(ms)`
  and `setTimeout` resolve from host timers. `ournet.timer.set(token, ms)`
  is the plain form (tokens below 2^32). Async handlers work, and their
  errors are logged.
- A handler that throws is logged and the plugin keeps running; a script
  that does not load (a syntax error) stops it, with the error in the log.
  `onRequest` must answer without waiting for later events.

## Measured (Windows x64 desktop, 14 October 2026)

`OURNET_SCRIPT_BENCH=1 dart test test/script_plugin_test.dart -n "compared
with Rust"` in `core`, through the real host (release native library, Dart
JIT). Wall times wait on the plugin's changes rather than polling (Windows
sleeps in 15.6 ms steps); CPU is the host's count for each plugin's calls,
time waiting on the app excluded. Other builds may have been running.

| | Rust | JavaScript |
|---|---|---|
| Package, zipped | tictactoe 58 KB, pong 42 KB | 3.8 KB, 4.7 KB, plus the runtime once: 1.2 MB (4.1 MB of wasm) |
| First start, compiling | 281 ms, 163 ms | 5.1 s, once per runtime version per device; later scripts start compiled |
| Start, compiled | 2.4 ms (init 0.06 ms CPU) | 18 ms (init 7.5 ms CPU: Boa's realm, the prelude, parsing) |
| A move, event to board shown | 2.9 ms (plugin CPU 0.22 ms) | 3.7 ms (2.0 ms) |
| A pong frame | 0.13 ms CPU | 0.31 ms CPU (0.7% of a core) |

The engine is fast enough: a move costs 2 ms of CPU and a frame a third of a
millisecond, and a script package is a fifteenth the size of a Rust one.
What is slow is compiling the 4 MB runtime the first time, and again when an
app update changes the compiler; a phone will take longer still. So Boa
stays, and QuickJS is not needed for speed. Next, in order:

1. **Compile the runtime ahead of need**, on a background thread when it is
   installed or the app updates, so nobody waits on a script's first start.
   Measure on an Android device.
2. Trim the engine (Boa features, `opt-level`), which also shortens that
   compile. QuickJS (about a quarter the size) only if a phone shows that is
   not enough.
3. Fetch a non-bundled runtime with the script plugin that needs it. Offers
   name the runtime now, but only the bundled one installs alongside.
4. Memory per script instance is not measured (the host has no counter).

Found on the way: Pong runs at about 21 frames a second on Windows rather
than 30, Rust and JavaScript alike, because the host's 33 ms timer wait is
rounded up to Windows' 15.6 ms steps (47 ms).

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
  interface (built as `package-files.read(name) -> option<list<u8>>`, always
  granted, since `package` is a WIT keyword).
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

Done (see "Built" and "Measured"). It went straight to shape D, since the
host change was small, with both tictactoe and pong rewritten.
