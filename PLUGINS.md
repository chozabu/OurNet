# Plugin system design

Status: proposal. Answers open decision 11 in [CORE_IDEA.md](CORE_IDEA.md)
("What may plugins access, execute and publish?") and the open questions in its
*Plugins* section.

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
Flutter UI isolate ── renders RFW trees, host surfaces, slots
       │  (ports, async only)
Dart node (core/transport) ── PluginRegistry: kinds, validators, sections,
       │                       request handlers, from both tiers
       │  FFI + NativePort
native (Rust) ── PluginHost: wasmtime engine, one instance per plugin,
                 worker threads, fuel/epoch, memory limits, hot reload
       └── native data planes: media, TUN, datagram pipes (phase 4)
```

- **Off the UI thread by construction.** Plugin instances run on Rust worker
  threads. Every host→plugin call is async; results return over a Dart
  `NativePort`. A plugin can never block a frame.
- **Incremental by construction.** Plugins get cursors (`changes since c`) and
  subscriptions, never "scan all objects". Query APIs are indexed and paged,
  matching AGENTS.md's no-rescan rule.
- **Hot reload.** On a new component: call old instance's optional
  `save-state() -> list<u8>`, instantiate new, call `restore(bytes)`, swap.
  UI trees re-render. Dev mode watches a path (`ournet plugin dev ./target/…`)
  on desktop, or pushes over the device link to a phone.

## API surface (WIT sketch)

Package `ournet:plugin@0.1.0`. Names illustrative.

```wit
interface types {
  type person-id = string;     // Ed25519 root public key
  type device-id = string;
  type object-id = string;
  record object {
    id: object-id, author: person-id, device: device-id,
    kind: string, space: string, audience: list<person-id>,
    created: u64, payload: list<u8>,        // canonical JSON, decrypted
    via: list<person-id>,                   // provenance chain
  }
  enum audience-kind { personal, people, group, public }
}

// Signed, synced, durable data. The host signs, encrypts, validates envelope
// rules and applies audience/relay policy. Plugins never see keys.
interface objects {
  publish: func(kind: string, space: string, audience: list<person-id>,
                payload: list<u8>, expires: option<u64>) -> result<object-id, error>;
  get: func(id: object-id) -> option<object>;
  query: func(q: query, cursor: option<cursor>) -> page;   // indexed, paged
  subscribe: func(filter: query) -> subscription;          // pushes `on-objects`
  hide: func(id: object-id) -> result<_, error>;
}

// Ephemeral F2F messaging to admitted devices only.
interface live {
  request: func(device: device-id, payload: list<u8>) -> future<result<list<u8>, error>>;
  open-stream: func(device: device-id) -> result<stream, error>;     // reliable, ordered
  send-datagram: func(device: device-id, data: list<u8>) -> result<_, error>;
}

interface identity {          // read-only views, gated per field
  me: func() -> person-id;
  contacts: func() -> list<contact>;   // names, avatars, devices, online
  groups: func() -> list<group>;
}

interface storage {           // private, per plugin, per device; not synced
  get: func(key: string) -> option<list<u8>>;
  set: func(key: string, value: list<u8>);
}

interface ui {
  render: func(surface: surface-id, tree: list<u8>);        // RFW binary
  notify: func(n: notification);
  open: func(route: string);
}

world plugin {
  import objects; import live; import identity; import storage; import ui;
  // optional, granted per manifest: media, tun, canvas, http, files, clock, random
  export init: func(ctx: context);
  export validate: func(kind: string, payload: list<u8>) -> bool;
  export on-objects: func(sub: subscription, objects: list<object>);
  export on-request: func(device: device-id, payload: list<u8>) -> list<u8>;
  export on-stream: func(device: device-id, s: stream);
  export on-datagram: func(device: device-id, data: list<u8>);
  export on-event: func(surface: surface-id, event: string, args: list<u8>);
  export save-state: func() -> list<u8>;
  export restore: func(state: list<u8>);
}
```

### Data on the wire

- **Kinds are namespaced** by plugin: `x.<plugin-id>.<kind>` (spaces likewise
  when a plugin needs its own). Core kinds stay unprefixed. Builds without the
  plugin already store and relay these (`_ => true`), so a group member without
  the plugin is still a relay.
- **Validation** keeps two layers: the host enforces envelope, signature,
  audience, size caps and the existing generic payload checks; the plugin's
  `validate` export decides content for its kinds. Objects failing either are
  dropped as today. Add a hard per-kind payload cap for plugin kinds.
- **Provenance**: add an optional signed field `app: "<plugin-id>@<version>"`
  to objects published by a plugin. Additive; older builds ignore it. Readers
  can see which plugin wrote something and with which version, which fits
  the accountability goal.
- **Live traffic**: one new request type, `plugin`, carrying
  `{plugin, payload}`. Older peers answer `Unknown request`; peers without the
  plugin refuse individually. Streams open a bi-stream whose first line is
  `{type: "plugin_stream", plugin}` then raw bytes. Datagrams get a framing
  prefix (varint channel → plugin) since none are used today. All on
  `ournet/2`; no ALPN change. Only admitted, non-revoked devices, as now.
- Peers advertise installed plugin IDs+API versions in `caps`, so a plugin
  can tell which friends can play/call/route.

### Permissions

Manifest declares; the user grants at install; widening on update re-prompts.
Grants are imports: an ungranted interface is simply not linked.

| Capability | Default | Notes |
|---|---|---|
| Own kinds: publish/query/subscribe | granted | Only `x.<self>.*` |
| Core kinds read (e.g. `chat_msg` in a scope) | ask | Scoped: a group, a conversation, or "where I'm opened" |
| Core kinds publish (post into a chat/forum) | ask, per scope | Rare; shows the `app` field |
| `identity.contacts` / groups | ask | Names and online state; no keys ever |
| `live` (request/stream/datagram) | ask | Rate- and bandwidth-limited per plugin, counted in `traffic` |
| `storage` | granted | Quota |
| `media` (camera/mic/WebRTC session) | ask, per use | OS prompt still applies |
| `tun` (VPN) | ask, privileged | Android VpnService, wintun on Windows |
| `http` (outside network) | ask, per host | Off by default: F2F first |
| `canvas`, `notifications`, `files` (picker) | ask | |

A plugin never gets: keys, raw store access, other plugins' data, the ability
to admit/revoke devices, or synchronous calls into the UI.

### UI integration

Plugins contribute to fixed **slots** rather than arbitrary screens, so the app
stays coherent (CORE_IDEA §9) and scopes keep working:

- **Section**: an entry in navigation, declaring which scopes it allows
  (extends `ScopedSection`'s table with plugin rows).
- **Object renderer**: how `x.<id>.<kind>` appears in Activity, chat
  timelines and search.
- **Composer actions**: "Start a poll / game / call" in a conversation or group.
- **Settings page** and **notification** handlers.

Rendering:

1. **RFW trees** (`package:rfw`, maintained by the Flutter team): the plugin
   sends a widget tree plus data; events come back via `on-event`. Host
   supplies an OurNet widget library (lists, avatars, `ThumbnailImage`,
   composer, buttons) so plugins look native and inherit the performance
   rules.
2. **Canvas**: a draw-command list per frame, or an RGBA buffer shared into a
   Flutter `Texture`, for games.
3. **Host surfaces**: video renderers, map view, file picker; the plugin
   lays them out and drives them, the host owns the pixels.
4. Later, optionally, **webview panels** for plugins that want HTML; same
   permission model, behind its own capability.

### Performance-critical plugins

The rule: **plugins control data planes; they do not carry bulk bytes through
WASM unless they must.**

- **Video calls**: host keeps WebRTC (`flutter_webrtc`, already shipped). The
  `media` interface exposes sessions, tracks and devices; the plugin does
  signalling (over `live`), policy and layout. The existing calls and group
  calls can become a plugin this way. Codecs in WASM are not viable.
- **VPN over F2F**: host provides `tun` and a native pipe TUN ↔ iroh
  datagrams/streams; the plugin chooses peers, routes, ACLs, and may install
  a per-packet filter (a WASM call per packet is fine to hundreds of Mbps;
  measure). This needs the plugin host and iroh endpoint in **the same Rust
  library**. Today iroh comes from `vendor/iroh_dart` (and a signed
  precompiled DLL on Windows) while `native` is separate, so packets would
  otherwise round-trip through Dart. Phase 4 builds one cdylib containing
  iroh, the plugin host and the data planes. Multi-hop routing to friends of
  friends is a separate protocol question (CORE_IDEA open decision 1).
- **Games**: datagrams/streams + canvas cover real-time; turn-based games are
  just objects + RFW.

### Scripting as a plugin

A `script-host` plugin embeds an interpreter compiled to WASM (QuickJS via
`javy`/`rquickjs`, or Lua) and exposes the same WIT API to scripts. A script
plugin is a manifest naming `script-host` as its runtime plus source files.
It gets the same permissions, sandbox and hot reload, at interpreter speed.
No second runtime in the core, and it can be replaced (Python via
`componentize-py`, etc.) without touching the app.

### Packaging, distribution, versioning

- **Package**: zip with `manifest.toml` (id, name, version, `api = "0.1"`,
  capabilities, slots, kinds), `plugin.wasm` (or scripts + runtime), RFW
  libraries, assets.
- **Signed by the author's OurNet identity.** Signature proves authorship,
  not safety (CORE_IDEA §8); the sandbox and grants carry the safety story.
- **Distributed over F2F**: a `plugin_release` object in a plugin's space,
  with the package as a chunked attachment. Friends see who published it and
  which friends run it, using existing provenance. Updates arrive like any
  object; install/upgrade stays a user action, re-prompting on new
  capabilities.
- **API versioning**: WIT packages are semver'd. The host links every API
  major it supports side by side (`ournet:plugin@0.x`, `@1.x`), so old plugins
  keep working. Additive within a major. Same discipline as the protocol.
- **Data versioning**: plugins own their kinds and follow AGENTS.md's
  additive rule; a payload `v` field is recommended. Mixed versions across
  friends are normal.
- **Precompiled cache**: compile `.wasm` to native once per device
  (`Module::serialize`), keyed by hash + engine version, so startup is a
  mmap, not a recompile.

## Migration path

**Phase 0: registry, no runtime.** Introduce `PluginRegistry` in core: kinds +
validators, section/slot descriptors, request handlers, object renderers.
Turn the `validContent` switch and the `PeerNetwork` request switch into
lookups. Move one feature onto it (public chats: `chat`, `chat_msg`,
`chat_hide`, self-contained). No protocol change. This is where most of the
"move features into plugins" work actually happens.

**Phase 1: WASM host, v0.1 API.** wasmtime in `native`; `objects`, `storage`,
`identity`, `ui` (RFW); `plugin` request type; `app` field; manifest +
permission prompt; dev hot reload. Proving plugins: polls (objects only) and
a re-implementation of public chat as a WASM plugin for parity and benchmarks
against the Dart version (extend `PERFORMANCE.md`).

**Phase 2: scripting + distribution.** `script-host` plugin; `plugin_release`
objects and install/update UI; per-plugin traffic and storage in Settings.

**Phase 3: real-time.** Streams, datagrams with framing, canvas surface.
Proving plugin: a small real-time game.

**Phase 4: native data planes.** Single Rust library with iroh + plugin host;
`media` interface, then move calls/group calls onto it; `tun` + VPN plugin.

Candidates to move, in order of ease: public chats, polls/votes, listings,
location sharing, forums, calls. Staying core: identity, devices, keys,
contacts, sync/relay policy, drive, notes, calendar (performance-tuned and
foundational; revisit later).

## Open questions

1. Can a plugin publish core kinds at all, or only reference them? (Proposed:
   only with a per-scope grant and the `app` field.)
2. Should peers relay public plugin objects in spaces they follow without the
   plugin? (Today: yes. Fine unless abuse shows otherwise; size caps help.)
3. Background execution on Android: which plugins may run while the app is
   backgrounded (VPN must; games must not)?
4. iOS: interpreter speed acceptable for which plugin classes?
5. Review/curation: is "friends who run it" enough, or do communities want
   allow-lists?
