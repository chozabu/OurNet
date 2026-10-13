# Plugin system design

Status: implemented on Windows and Android (October 2026): the registry, the
WebAssembly host, the app's plugin pages, live messages, datagrams, virtual
interfaces and five first-party plugins. Distribution over F2F, scripting and
the media interface are still to do; see Status below. Answers open decision 11
in [CORE_IDEA.md](CORE_IDEA.md) ("What may plugins access, execute and
publish?").

Where building it showed a better way than first proposed, the design below
was changed, and each change is marked **Revised**.

## Goals

- New experiences (forum/chat variants, games, polls, wikis, video calls, a VPN
  over F2F) without growing the core.
- Existing features can move behind the same contract.
- Every platform OurNet targets or might target: Windows, Android, Linux, macOS,
  iOS, headless node.
- Fast enough for real-time media and packet forwarding.
- Hot reload in development, and updates without restarting the app.
- Higher-level scripting available, ideally as a plugin rather than a second
  runtime in the core.
- Plugins reuse identity, signing, audiences, encryption and provenance; they
  never hold keys. Access is explicit and constrained (CORE_IDEA §8).

## Constraints from this codebase

These decide most of the answer.

1. **The app is Flutter, compiled AOT in release.** Dart cannot load new Dart
   code at runtime in release builds, so "plugins in Dart" can only mean
   compiled-in modules. Third-party code needs a different runtime.
2. **Flutter widgets cannot be loaded at runtime either.** Plugin UI has to be
   data (a widget description the host renders), a texture, or a webview.
3. **We already ship Rust per target.** `native/` is a Rust crate built by a
   Dart build hook for every target, called through FFI. A plugin runtime
   written in Rust slots in there with no new toolchain.
4. **The object model is already plugin-shaped.** A `SignedObject` is
   `{kind, space, audience, payload, …}` signed by a device. `validContent`
   ends in `_ => true`, so unknown kinds already validate, store, sync and relay
   (public ones only within followed spaces, private ones to their audience and
   named relays). A friend without a plugin still carries its private data.
5. **Live traffic is a closed switch.** `PeerNetwork` handles `typing`,
   `position`, `groupcall`, `signal`, … and answers anything else with
   `Unknown request`. QUIC datagrams are exposed by `iroh_quic` but unused.
6. **Additive compatibility rules** (AGENTS.md): new kinds, optional fields and
   request types are fine; no ALPN change needed.
7. **Responsiveness rules** (AGENTS.md): nothing heavy on the UI isolate; no
   history rescans on each change. Plugins must be held to the same rules by
   construction, not by review.
8. **Store policy.** Google Play forbids downloading native code (`.so`,
   dex) outside Play, but exempts code run in a VM/interpreter without direct
   Android API access. iOS forbids loading native code and JIT outside
   WebKit. A sandboxed bytecode runtime is the only route that stays inside
   both.

## Options

| | Native dylib (C ABI) | **WASM components (wasmtime)** | Embedded JS/Lua | Out-of-process (IPC) | Webview (HTML/JS) |
|---|---|---|---|---|---|
| Platforms | Desktop + Android only; not iOS; Play policy breach if downloaded | All. JIT on desktop/Android, interpreter on iOS | All | Desktop only in practice | All, but WebView2 on Windows, heavy on Android |
| Speed | Native | ~1.1–2× native compute, cheap calls (tens of ns) | 10–50× slower compute (QuickJS/Lua) | Native compute, IPC per call | JS JIT, slow bridge |
| Isolation | None: a plugin is the app | Strong: memory, fuel/epoch limits, only the imports we hand it | Good (interpreter) | Strong (OS process) | Good |
| Hot reload | Unsafe unload, leaks | Drop instance, instantiate new one | Easy | Restart process | Reload page |
| Languages | Rust/C/C++ | Rust, C/C++, Go, Zig, AssemblyScript, JS/Python via componentised runtimes | One | Any | JS |
| Builds to ship | Per OS × arch | One `.wasm` | One script | Per OS × arch | One bundle |
| Typed API / versioning | Hand-rolled ABI | WIT interfaces, semver'd packages | Hand-rolled | Hand-rolled schema | Hand-rolled |

Dropped:

- **Native dylibs**: no sandbox, a binary per target, unsafe unload, and
  disallowed on iOS and (when downloaded) on Play. Contradicts "constrained"
  in CORE_IDEA.
- **Out-of-process**: unavailable on mobile, which is half the user base.
- **Webview as the runtime**: memory per plugin, a WebView2 dependency on
  Windows, and the wrong shape for packet- or media-rate work. Kept as an
  optional *UI surface* later (below), not as the execution model.
- **JS/Lua as the runtime**: right for scripting, wrong as the foundation for
  a VPN or a game loop. Ships as a plugin instead (below).

## Recommendation

**WebAssembly components on wasmtime, hosted in the existing `native` Rust
crate, with a WIT-defined API. Plugin UI is a declarative widget tree rendered
by Flutter (`package:rfw`) plus a few host-owned surfaces. Bulk data paths
(media, packets) stay native and are *configured* by plugins, not carried
through them. Scripting is a WASM plugin that hosts a script engine.**

Two tiers share one contract:

- **Bundled modules** (Dart, compiled in): existing features, refactored onto
  the same registry, manifest and permission model. Free to stay in Dart.
- **Plugins** (WASM components): third-party and new first-party features,
  installed and updated at runtime.

The host does not care which tier provides a kind, section or request handler.
That is what makes "move a feature into a plugin" an incremental step rather
than a rewrite: first move it onto the registry (cheap, Dart), then port it to
WASM only if there is a reason to.

### Why it fits

- One `.wasm` runs everywhere OurNet runs, including a headless node.
- wasmtime: Cranelift JIT on x86-64/arm64 desktop and Android; its Pulley
  interpreter (or WAMR) where JIT is not allowed (iOS). Same component, same
  API.
- Sandbox by default: a plugin can only call the imports its manifest was
  granted. Memory caps via `ResourceLimiter`; runaway loops stopped by epoch
  interruption; a trap kills the instance, not the app.
- Hot reload is native to the model: instances are disposable.
- Component model + WIT gives typed, versioned interfaces and multi-language
  guest bindings (`wit-bindgen`, `cargo component`, `jco`, `componentize-py`).

### Costs to accept

- Binary size: wasmtime with Cranelift adds several MB per Android ABI.
  Measure; an interpreter-only build is smaller if it matters on mobile.
- Plugin authors write Rust/C/Go/etc. or use the scripting plugin; there is
  no "write a plugin in Dart".
- UI is less expressive than hand-written Flutter until the widget vocabulary
  grows.

## Architecture

```
Flutter UI isolate ── PluginView: RFW library + data per surface; events back
       │  (streams; never waits on a plugin)
core Plugins ─────── manifests, grants, imports answered from the Node,
       │             insertion-cursor feed, live/datagram routing
       │  Registry ─ kinds + checks, request and datagram handlers, sections,
       │             capabilities: built-in features and plugins alike
       │  FFI (leaf calls) + NativeCallable.listener
native PluginHost ── wasmtime (Cranelift; component model; no WASI), one thread
       │             per plugin, CPU budget, memory cap, compile cache, timers,
       │             storage, rate limits
       └── tun ──── system interface ⇄ plugin thread, without Dart
```

- **Registry** (`core/lib/src/registry.dart`). A `Module` declares the kinds a
  feature owns and how their content is checked. Built-in features declare
  constant modules (`builtin_modules.dart`; public chats own theirs in
  `public_chats.dart`), so every isolate that verifies objects has the same
  table. A per-node `Registry` adds what runs: plugin kind checks, live request
  handlers (typing, position, calls and plugins all answer through it),
  datagram handlers, navigation sections and advertised capabilities.
- **Native host** (`native/rust/src/plugin.rs`, WIT in `native/rust/wit/`).
  Each plugin gets a thread and a job queue. Dart sends calls as a JSON line
  optionally followed by raw bytes; results, imports and notices come back the
  same way through a `NativeCallable.listener`, so they arrive on the event
  loop and never block a frame. Every FFI function is a leaf call that only
  queues.
- **Imports block the plugin's thread, not Dart's** (**Revised**: no WIT
  `future`s). An import Dart must answer (publish, query, contacts) posts a
  question and waits on that plugin's answer queue; Dart answers when it can.
  What needs no Dart is answered in Rust: clock, timers, storage, rate limits,
  logging caps. Calls whose answer comes later are split instead:
  `live.send` returns an ID and its reply arrives as `on-reply`.
- **Limits.** A call may use 5 s of CPU, counted by an epoch callback that
  excludes time spent waiting on the host; over it, the instance traps and is
  dropped, and the app offers a restart. Linear memory is capped at 64 MiB,
  storage at 16 MiB, `live.send` at 60/s and datagrams at 4000/s.
- **Incremental by construction.** A plugin is sent every object of its kinds
  once, in storage order, by `Store.objectsAfter` cursors kept per plugin and
  kind. A cursor moves when the plugin has taken the page, so a page it
  crashed on comes again. History is read with `objects.query`, through the
  indexes, 500 at most. Nothing scans.
- **Hot reload.** Installing over a running plugin swaps the instance:
  `save-state`, new instance, `restore`, `init`. Storage, timers and cursors
  stay with the host. On desktop, Settings › Plugins › Developer folder
  watches `plugins/dist`, which `cargo run -p pack --release -- --watch`
  rewrites as sources change.
- **Compile cache.** Compiled code is saved per package hash and engine, so
  every start after the first deserialises instead of compiling.

## API (`ournet:plugin@0.1.0`)

The full world is `native/rust/wit/plugin.wit`; the Rust SDK is
`plugins/sdk`. In brief:

| Interface | Grant | Calls |
|---|---|---|
| `log`, `clock`, `storage`, `ui` | always | log; now, set/cancel timer; get/set/remove/keys; update a surface's data, notify |
| `objects` | `objects` | publish (own kinds; personal, people, group or public audience), get, query, follow a public space |
| `identity` | `identity` | me, this device, contacts (devices: name, online, runs this plugin), groups (space, name, members) |
| `live` | `live` | send (reply via `on-reply`), datagram |
| `tun` | `tun` | open (address, prefix, routes, MTU), write, close |

Exports: `init`, `on-objects`, `on-open(surface, context)`, `on-event`,
`on-request`, `on-reply`, `on-timer`, `on-datagram`, `on-packet`,
`save-state`, `restore`. The SDK gives each a default that does nothing.

- **Ungranted means refused** (**Revised**). A component imports only what
  its code uses, so the host compares its imports with its grants when
  loading and refuses one that reaches further. Dart checks the grant again
  on every import it answers.
- **`validate` became declarative** (**Revised**). Content checks run
  synchronously on every store, read and receive, on whichever isolate does
  it; calling a plugin there would block. The manifest declares each kind's
  fields instead (type, `max`, `min`, `required`, `values`, list `items`), and
  the host compiles them into a `ContentCheck`. Plugins still check what they
  read.
- **`ui.update` merges** (**Revised**): it sets top-level keys of a surface's
  data, so a plugin can update a counter without resending a page.

### Data on the wire

As proposed, all on `ournet/2` and additive:

- Kinds are `x.<plugin>.<name>`. Every build checks them against a 64 KiB
  payload cap and the generic field rules, and stores and relays them; the
  plugin's schema applies where it is installed (`Registry.accepts`).
- Objects a plugin publishes carry an optional signed envelope field
  `app: "<id>@<version>"` (`SignedObject.app`).
- Live request type `plugin`: `{plugin, payload (base64)}`, reply
  `{payload}`; poolable. Refused individually where the plugin is not running.
- **Datagrams** (**Revised**): a device opens a `datagrams` request on a
  connection of its own and holds it while datagrams flow (30 s idle), so the
  served side keeps the connection open; both sides read QUIC datagrams on it.
  Each is `[1][channel length][channel][data]` with channel `p:<plugin>`, and
  goes to `Registry.handleDatagrams`. Older builds refuse the request, and the
  datagram reports not sent.
- Each running plugin granted `live` is advertised as capability
  `p:<plugin>`, after the built-in ones and within the 32 a peer reads;
  `identity.contacts` reports it per device.

### Permissions

The install prompt lists the grants in plain words; an update asking for more
says which are new. `objects`, `identity`, `live` and `tun` are grantable;
`log`, `clock`, `storage` and `ui` are always there. Not yet: publishing or
reading core kinds (open question 1), `media`, `http`, `files`. A plugin never
gets keys, raw store access, other plugins' data or synchronous calls into the
UI.

### UI

A package's `ui.rfwtxt` is an RFW library; each section names the widget
(`surface`) its page shows. `PluginView` renders it over the surface's data and
sends events back with the widget's arguments plus what the widget adds
(`value`, `target`, `x`/`y`, `key`/`down`). The libraries are `core.widgets`,
`core.material` and **`ournet`**: `TextInput`, `Markup` (headings, lists,
bold, italic, `[[links]]`), `Canvas` (rect, circle, line and text commands in
a scaled space, with tap and drag), `Keys`, `Avatar`, `PersonName`, `TimeAgo`.

Learned building it:

- RFW's `ListView` builds children lazily during layout, where a child's first
  data read cannot subscribe. `PluginView` replaces it with one that resolves
  its children while building. Plugin lists are short; a long one should page.
- RFW's parser rejects carriage returns, so package interfaces are read with
  Unix line ends.
- Numbers for sizes and canvas commands may be whole or not.
- A section's page gets `on-open` with the scope: personal, public, all, or a
  group's space and name. Plugins decide from it where their data lives.

### Performance-critical paths

- **Packets** never cross into Dart on the interface side: the `tun`
  backend's reader thread queues them to the plugin's thread (dropping beyond
  1024 waiting), and `tun.write` goes straight to the system. The hop to a
  friend still passes through Dart's iroh, one datagram each, until phase 4's
  single library. Android opens the interface through `FriendVpn` (a
  VpnService, with the system's consent) and hands its descriptor to Rust;
  Windows opens a Wintun adapter, which needs `wintun.dll` beside the app and
  administrator rights; tests use a memory interface.
- **Real-time** play is datagrams plus Rust timers: Pong's host steps at 30 Hz
  and sends the whole state each tick, so a lost datagram costs one frame.
- **Size**: wasmtime with Cranelift takes the native library to 13 MB on
  Windows x64, 8.4 MB on Android arm64 and 5.4 MB on armv7 (32-bit hosts run
  Pulley, the interpreter). Not yet trimmed.

### Packaging

A `.ournet-plugin` is a zip of `manifest.json` (**Revised**: JSON, like
everything else OurNet signs, so the app needs no TOML parser), `plugin.wasm`
(a component), `ui.rfwtxt` and `assets/`. `plugins/` is a Cargo workspace:

- `sdk`: bindings and a friendlier surface over them
  (`ournet_plugin::plugin!(Type)`).
- `pack`: builds each plugin for `wasm32-unknown-unknown`, wraps it as a
  component with `wit-component`, and zips it into `plugins/dist`.
- `echo`, the test plugin, and the first-party plugins.

Packages ship in `app/assets/plugins` and install from Settings › Plugins, as
do files.

## First-party plugins

| Plugin | Shows | Uses |
|---|---|---|
| `wiki` | Linked pages per scope (your own, a group's, a public commons), history, a notice when two people edit at once | objects, identity |
| `microblog` | Public posts in each person's own space, followed friend to friend; group posts; likes and replies | objects, identity |
| `tictactoe` | Turn-based play as signed moves between two people; both reach the same board | objects, identity |
| `pong` | Real-time play over datagrams; practice against the computer | live, Canvas, timers |
| `vpn` (Friend network) | 10.77.0.0/16 between your devices and friends you allow; addresses from device IDs; senders' addresses checked | identity, live, tun |

Tests: `core/test/plugins_test.dart` and `vpn_plugin_test.dart` run the real
host; `app/test/plugin_view_test.dart` draws each plugin with RFW (set
`PLUGIN_SHOTS` for screenshots); `plugin_ui_test.dart` parses every interface.

## Status

| Phase | State |
|---|---|
| 0. Registry | Done: kinds, requests, datagrams, sections, capabilities |
| 1. WASM host, v0.1 API, app pages, manifest and grants, hot reload | Done. Polls and a public-chat port were not written; the wiki and microblog prove the objects API instead |
| 2. Scripting, F2F distribution, per-plugin traffic and storage in Settings | Not started |
| 3. Streams, datagrams, canvas | Datagrams and canvas done; nothing needs streams yet |
| 4. Single library with iroh, `media`, `tun` and a VPN | `tun` and the VPN plugin done; iroh is still separate; `media` not started |

Not yet verified: the Windows Wintun path (needs `wintun.dll` and an elevated
app), and anything on an Android device (the APK builds for arm64 and armv7).
Next, in order of use: per-plugin traffic in Settings; `plugin_release` objects
so friends can share plugins; a foreground service keeping the VPN up when
Android backgrounds the app; measured budgets in `PERFORMANCE.md`; then the
single iroh library.

## Open questions

1. Can a plugin publish core kinds at all, or only reference them? (Proposed:
   only with a per-scope grant and the `app` field.)
2. Should peers relay public plugin objects in spaces they follow without the
   plugin? (They do, under the size cap.)
3. Background execution on Android: which plugins may run while the app is
   backgrounded (the VPN must; games must not)?
4. iOS: interpreter speed acceptable for which plugin classes?
5. Review/curation: is "friends who run it" enough, or do communities want
   allow-lists?
6. Microblog likes count only from people this person follows, since a like
   lives in the liker's space. Enough, or should likes travel with the post?
