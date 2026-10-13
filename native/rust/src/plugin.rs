//! The plugin host: WebAssembly components on wasmtime (see PLUGINS.md and
//! `wit/plugin.wit`).
//!
//! Each plugin runs on a thread of its own, so a slow or looping plugin
//! never holds up the app or another plugin. Dart drives it with messages:
//! it queues calls (`ournet_plugin_call`), and is posted results, imports to
//! answer and notices through the callback given to `ournet_plugins_init`.
//! A message is a line of JSON, optionally followed by raw bytes after a
//! newline, so payloads travel without re-encoding.
//!
//! What a plugin can do without Dart (clock, timers, storage, logging limits)
//! is done here; signing, storage of objects and the network stay in Dart and
//! are reached by blocking the plugin's thread on Dart's answer.

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use wasmtime::component::{Component, HasSelf, Linker};
use wasmtime::{Config, Engine, Store, StoreLimits, StoreLimitsBuilder, UpdateDeadline};

wasmtime::component::bindgen!({ path: "wit", world: "plugin" });

use crate::tun as interface;
use ournet::plugin::{clock, identity, live, log, objects, storage, tun, types, ui};

/// Posts one message to Dart: the plugin's handle and a buffer Dart frees
/// with `ournet_free`.
type Post = unsafe extern "C" fn(handle: u64, data: *mut u8, len: usize);

/// Bumped when the message protocol or the WIT world changes.
const HOST_VERSION: u32 = 1;

/// CPU time one call into a plugin may use, excluding time spent waiting on
/// the host. A plugin over it is stopped: it has looped, not worked.
const CALL_BUDGET: Duration = Duration::from_secs(5);

/// How long an import waits for Dart before failing.
const ANSWER_WAIT: Duration = Duration::from_secs(30);

/// Linear memory one plugin may grow to.
const MEMORY_LIMIT: usize = 64 << 20;

/// Bytes of keys and values one plugin may keep in `storage`.
const STORAGE_QUOTA: usize = 16 << 20;

/// `live.send`: messages per second on average, and in a burst.
const SEND_RATE: f64 = 60.0;
const SEND_BURST: f64 = 120.0;

/// `live.datagram`: per second on average, and in a burst; and the largest.
const DATAGRAM_RATE: f64 = 4000.0;
const DATAGRAM_BURST: f64 = 8000.0;
const DATAGRAM_BYTES: usize = 1100;

/// Packets from a `tun` interface waiting for the plugin; more are dropped,
/// as a congested link would (TCP sends them again).
const PACKET_QUEUE: usize = 1024;

/// Epoch ticks are wall time; the deadline callback turns them into CPU time.
const TICK: Duration = Duration::from_millis(10);

static POST: OnceLock<Post> = OnceLock::new();
static ENGINE: OnceLock<Result<Engine, String>> = OnceLock::new();
static PLUGINS: Mutex<Option<HashMap<u64, Handle>>> = Mutex::new(None);
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

/// What Dart holds of a running plugin: where its jobs and answers go.
struct Handle {
    jobs: Sender<Job>,
    answers: Sender<(u64, Vec<u8>)>,
}

enum Job {
    Call(Vec<u8>),
    Reload(Vec<u8>),
    /// An IP packet from the plugin's `tun` interface.
    Packet(Vec<u8>),
    Stop,
}

fn engine() -> Result<&'static Engine, String> {
    ENGINE
        .get_or_init(|| {
            let mut config = Config::new();
            config.wasm_component_model(true);
            config.epoch_interruption(true);
            config.cranelift_opt_level(wasmtime::OptLevel::Speed);
            // Hosts Cranelift cannot generate code for run the interpreter.
            #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
            {
                config
                    .target(if cfg!(target_pointer_width = "64") {
                        "pulley64"
                    } else {
                        "pulley32"
                    })
                    .map_err(|e| e.to_string())?;
            }
            let engine = Engine::new(&config).map_err(|e| e.to_string())?;
            let ticker = engine.clone();
            thread::Builder::new()
                .name("ournet-plugin-epoch".into())
                .spawn(move || loop {
                    thread::sleep(TICK);
                    ticker.increment_epoch();
                })
                .map_err(|e| e.to_string())?;
            Ok(engine)
        })
        .as_ref()
        .map_err(Clone::clone)
}

/// Posts [header] (and [body] after a newline) to Dart for [handle].
fn post(handle: u64, header: &Value, body: Option<&[u8]>) {
    let Some(post) = POST.get() else { return };
    let mut bytes = serde_json::to_vec(header).unwrap_or_default();
    if let Some(body) = body {
        bytes.push(b'\n');
        bytes.extend_from_slice(body);
    }
    let boxed = bytes.into_boxed_slice();
    let len = boxed.len();
    let data = Box::into_raw(boxed) as *mut u8;
    unsafe { post(handle, data, len) };
}

/// Splits a message into its JSON line and the bytes after it.
fn split(message: &[u8]) -> (&[u8], &[u8]) {
    match message.iter().position(|&b| b == b'\n') {
        Some(i) => (&message[..i], &message[i + 1..]),
        None => (message, &[]),
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// How a plugin is loaded: from Dart, as JSON.
#[derive(Deserialize)]
struct LoadConfig {
    id: String,
    /// Where the plugin's storage file lives; none keeps it in memory.
    #[serde(default)]
    dir: Option<PathBuf>,
    /// Where compiled code is cached between runs; none compiles each time.
    #[serde(default)]
    cache: Option<PathBuf>,
    /// The interfaces granted, by name (`live`, `identity`, …). A component
    /// importing anything else is refused.
    grants: Vec<String>,
}

/// Interfaces every plugin has.
const ALWAYS: [&str; 5] = ["types", "log", "clock", "storage", "ui"];

/// The plugin's private key-value store, kept in one file and written after
/// each call that changed it.
struct Storage {
    path: Option<PathBuf>,
    map: BTreeMap<String, Vec<u8>>,
    bytes: usize,
    dirty: bool,
}

impl Storage {
    fn open(dir: Option<&Path>) -> Storage {
        let path = dir.map(|d| d.join("storage.bin"));
        let mut map = BTreeMap::new();
        if let Some(data) = path.as_ref().and_then(|p| fs::read(p).ok()) {
            let mut at = 0;
            let take = |at: &mut usize| -> Option<Vec<u8>> {
                let len = u32::from_le_bytes(data.get(*at..*at + 4)?.try_into().ok()?) as usize;
                let value = data.get(*at + 4..*at + 4 + len)?.to_vec();
                *at += 4 + len;
                Some(value)
            };
            while at < data.len() {
                let (Some(k), Some(v)) = (take(&mut at), take(&mut at)) else {
                    break;
                };
                let Ok(k) = String::from_utf8(k) else { break };
                map.insert(k, v);
            }
        }
        let bytes = map.iter().map(|(k, v)| k.len() + v.len()).sum();
        Storage {
            path,
            map,
            bytes,
            dirty: false,
        }
    }

    fn flush(&mut self) {
        if !self.dirty {
            return;
        }
        self.dirty = false;
        let Some(path) = &self.path else { return };
        let mut out = Vec::with_capacity(self.bytes + 8 * self.map.len());
        for (k, v) in &self.map {
            out.extend_from_slice(&(k.len() as u32).to_le_bytes());
            out.extend_from_slice(k.as_bytes());
            out.extend_from_slice(&(v.len() as u32).to_le_bytes());
            out.extend_from_slice(v);
        }
        // Written aside and renamed, so a crash leaves the old or the new.
        let next = path.with_extension("next");
        if fs::write(&next, &out).is_ok() {
            let _ = fs::rename(&next, path);
        }
    }
}

/// Everything a plugin instance reaches through its imports. Survives a hot
/// reload: only the instance is replaced.
struct Host {
    handle: u64,
    answers: Receiver<(u64, Vec<u8>)>,
    next_question: u64,
    next_send: u64,
    limits: StoreLimits,
    storage: Storage,
    timers: BTreeMap<u64, Instant>,
    /// When the current call began, and how long of it was spent waiting on
    /// the host: the difference is what counts against [CALL_BUDGET].
    call_began: Instant,
    waited: Duration,
    send_tokens: f64,
    send_refill: Instant,
    datagram_tokens: f64,
    datagram_refill: Instant,
    /// This plugin's own queue, for packets from its interface.
    jobs: Sender<Job>,
    packets: Arc<AtomicUsize>,
    tun: Option<interface::Tun>,
}

/// A token bucket: whether one more may go now.
fn take(tokens: &mut f64, refill: &mut Instant, rate: f64, burst: f64) -> bool {
    let now = Instant::now();
    *tokens = (*tokens + now.duration_since(*refill).as_secs_f64() * rate).min(burst);
    *refill = now;
    if *tokens < 1.0 {
        return false;
    }
    *tokens -= 1.0;
    true
}

impl Host {
    /// Asks Dart to run import [function] and waits for its answer.
    fn ask(&mut self, function: &str, args: Value) -> Result<Value, String> {
        self.next_question += 1;
        let id = self.next_question;
        post(
            self.handle,
            &json!({"type": "import", "id": id, "fn": function, "args": args}),
            None,
        );
        let began = Instant::now();
        let answer = loop {
            match self.answers.recv_timeout(ANSWER_WAIT) {
                // An answer to an earlier question that timed out.
                Ok((other, _)) if other != id => continue,
                Ok((_, bytes)) => break Ok(bytes),
                Err(_) => break Err(format!("{function}: no answer from the host")),
            }
        };
        self.waited += began.elapsed();
        let value: Value = serde_json::from_slice(&answer?).map_err(|e| e.to_string())?;
        match value.get("error").and_then(Value::as_str) {
            Some(error) => Err(error.to_string()),
            None => Ok(value.get("ok").cloned().unwrap_or(Value::Null)),
        }
    }

    fn notice(&self, kind: &str, fields: Value) {
        let mut header = json!({"type": kind});
        if let (Value::Object(h), Value::Object(f)) = (&mut header, fields) {
            h.extend(f);
        }
        post(self.handle, &header, None);
    }
}

fn object_from(v: &Value) -> Option<types::Object> {
    Some(types::Object {
        id: v.get("id")?.as_str()?.into(),
        author: v.get("author")?.as_str()?.into(),
        device: v.get("device")?.as_str()?.into(),
        kind: v.get("kind")?.as_str()?.into(),
        space: v.get("space")?.as_str()?.into(),
        audience: v
            .get("audience")?
            .as_array()?
            .iter()
            .filter_map(|a| a.as_str().map(String::from))
            .collect(),
        created: v.get("created")?.as_u64()?,
        payload: v.get("payload")?.as_str()?.into(),
    })
}

impl types::Host for Host {}

impl log::Host for Host {
    fn log(&mut self, level: log::Level, message: String) {
        let level = match level {
            log::Level::Debug => "debug",
            log::Level::Info => "info",
            log::Level::Warn => "warn",
            log::Level::Error => "error",
        };
        let message: String = message.chars().take(2000).collect();
        self.notice("log", json!({"level": level, "message": message}));
    }
}

impl clock::Host for Host {
    fn now(&mut self) -> u64 {
        now_ms()
    }
    fn set_timer(&mut self, token: u64, delay: u32) {
        // A plugin keeps a bounded number of timers.
        if self.timers.len() < 256 || self.timers.contains_key(&token) {
            self.timers
                .insert(token, Instant::now() + Duration::from_millis(delay as u64));
        }
    }
    fn cancel_timer(&mut self, token: u64) {
        self.timers.remove(&token);
    }
}

impl storage::Host for Host {
    fn get(&mut self, key: String) -> Option<Vec<u8>> {
        self.storage.map.get(&key).cloned()
    }
    fn set(&mut self, key: String, value: Vec<u8>) -> Result<(), String> {
        let old = self
            .storage
            .map
            .get(&key)
            .map_or(0, |v| key.len() + v.len());
        let bytes = self.storage.bytes - old + key.len() + value.len();
        if bytes > STORAGE_QUOTA {
            return Err("storage quota exceeded".into());
        }
        self.storage.bytes = bytes;
        self.storage.map.insert(key, value);
        self.storage.dirty = true;
        Ok(())
    }
    fn remove(&mut self, key: String) {
        if let Some(v) = self.storage.map.remove(&key) {
            self.storage.bytes -= key.len() + v.len();
            self.storage.dirty = true;
        }
    }
    fn keys(&mut self, prefix: String) -> Vec<String> {
        self.storage
            .map
            .range(prefix.clone()..)
            .take_while(|(k, _)| k.starts_with(&prefix))
            .map(|(k, _)| k.clone())
            .collect()
    }
}

impl objects::Host for Host {
    fn publish(
        &mut self,
        kind: String,
        space: String,
        to: types::Audience,
        payload: String,
    ) -> Result<String, String> {
        let to = match to {
            types::Audience::Personal => json!({"personal": true}),
            types::Audience::People(people) => json!({"people": people}),
            types::Audience::Group => json!({"group": true}),
            types::Audience::Public => json!({"public": true}),
        };
        let id = self.ask(
            "objects.publish",
            json!({"kind": kind, "space": space, "to": to, "payload": payload}),
        )?;
        id.as_str()
            .map(String::from)
            .ok_or_else(|| "no object ID".into())
    }
    fn get(&mut self, id: String) -> Option<types::Object> {
        self.ask("objects.get", json!({"id": id}))
            .ok()
            .and_then(|v| object_from(&v))
    }
    fn query(&mut self, q: types::Filter) -> Vec<types::Object> {
        let args = json!({
            "kind": q.kind,
            "space": q.space,
            "author": q.author,
            "before": q.before.map(|(created, id)| json!([created, id])),
            "limit": q.limit.min(500),
        });
        match self.ask("objects.query", args) {
            Ok(Value::Array(items)) => items.iter().filter_map(object_from).collect(),
            _ => Vec::new(),
        }
    }
    fn follow(&mut self, space: String, on: bool) -> Result<(), String> {
        self.ask("objects.follow", json!({"space": space, "on": on}))
            .map(|_| ())
    }
}

impl identity::Host for Host {
    fn me(&mut self) -> String {
        self.ask("identity.me", Value::Null)
            .ok()
            .and_then(|v| v.as_str().map(String::from))
            .unwrap_or_default()
    }
    fn this_device(&mut self) -> String {
        self.ask("identity.device", Value::Null)
            .ok()
            .and_then(|v| v.as_str().map(String::from))
            .unwrap_or_default()
    }
    fn contacts(&mut self) -> Vec<identity::Contact> {
        let Ok(Value::Array(list)) = self.ask("identity.contacts", Value::Null) else {
            return Vec::new();
        };
        let text = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        list.iter()
            .map(|c| identity::Contact {
                person: text(c, "person"),
                name: text(c, "name"),
                devices: c
                    .get("devices")
                    .and_then(Value::as_array)
                    .map(|ds| {
                        ds.iter()
                            .map(|d| identity::Device {
                                id: text(d, "id"),
                                name: text(d, "name"),
                                online: d.get("online").and_then(Value::as_bool).unwrap_or(false),
                                has_plugin: d
                                    .get("plugin")
                                    .and_then(Value::as_bool)
                                    .unwrap_or(false),
                            })
                            .collect()
                    })
                    .unwrap_or_default(),
            })
            .collect()
    }
    fn groups(&mut self) -> Vec<identity::Group> {
        let Ok(Value::Array(list)) = self.ask("identity.groups", Value::Null) else {
            return Vec::new();
        };
        list.iter()
            .map(|g| identity::Group {
                space: g.get("space").and_then(Value::as_str).unwrap_or("").into(),
                name: g.get("name").and_then(Value::as_str).unwrap_or("").into(),
                members: g
                    .get("members")
                    .and_then(Value::as_array)
                    .map(|m| {
                        m.iter()
                            .filter_map(|p| p.as_str().map(String::from))
                            .collect()
                    })
                    .unwrap_or_default(),
            })
            .collect()
    }
}

impl live::Host for Host {
    fn send(&mut self, device: String, payload: Vec<u8>) -> u64 {
        self.next_send += 1;
        let id = self.next_send;
        let allowed = take(&mut self.send_tokens, &mut self.send_refill, SEND_RATE, SEND_BURST);
        if !allowed || payload.len() > 256 << 10 {
            // Answered at once, as a reply the plugin handles like any other.
            post(
                self.handle,
                &json!({"type": "refuse", "request": id, "error": "rate limited"}),
                None,
            );
            return id;
        }
        post(
            self.handle,
            &json!({"type": "send", "request": id, "device": device}),
            Some(&payload),
        );
        id
    }
    fn datagram(&mut self, device: String, data: Vec<u8>) -> Result<(), String> {
        if data.len() > DATAGRAM_BYTES {
            return Err("datagram too large".into());
        }
        if !take(&mut self.datagram_tokens, &mut self.datagram_refill, DATAGRAM_RATE, DATAGRAM_BURST) {
            return Err("rate limited".into());
        }
        post(self.handle, &json!({"type": "datagram", "device": device}), Some(&data));
        Ok(())
    }
}

impl tun::Host for Host {
    fn open(&mut self, address: String, prefix: u8, routes: Vec<String>, mtu: u16) -> Result<(), String> {
        let ip: std::net::Ipv4Addr = address.parse().map_err(|_| "not an IPv4 address")?;
        if prefix > 32 || !(576..=9000).contains(&mtu) || routes.len() > 32 {
            return Err("bad interface settings".into());
        }
        self.tun = None;
        let answer = self.ask(
            "tun.open",
            json!({"address": address, "prefix": prefix, "routes": routes, "mtu": mtu}),
        )?;
        let kind = if let Some(fd) = answer.get("fd").and_then(Value::as_i64) {
            interface::Kind::Fd(fd as i32)
        } else if let Some(name) = answer.get("wintun").and_then(Value::as_str) {
            interface::Kind::Wintun(name.into())
        } else if answer.get("memory").and_then(Value::as_bool) == Some(true) {
            interface::Kind::Memory
        } else {
            return Err("the app opened no interface".into());
        };
        let jobs = self.jobs.clone();
        let pending = self.packets.clone();
        let deliver: interface::Deliver = Box::new(move |packet| {
            if pending.load(Ordering::Relaxed) >= PACKET_QUEUE {
                return true;
            }
            pending.fetch_add(1, Ordering::Relaxed);
            jobs.send(Job::Packet(packet)).is_ok()
        });
        let handle = self.handle;
        let memory = Box::new(move |packet: &[u8]| post(handle, &json!({"type": "tun.write"}), Some(packet)));
        let config = interface::Config { address: ip, prefix, routes: &routes, mtu };
        self.tun = Some(interface::Tun::open(kind, &config, deliver, memory)?);
        Ok(())
    }
    fn write(&mut self, packet: Vec<u8>) {
        if let Some(tun) = &self.tun {
            tun.write(&packet);
        }
    }
    fn close(&mut self) {
        if self.tun.take().is_some() {
            self.notice("tun.close", json!({}));
        }
    }
}

impl ui::Host for Host {
    fn update(&mut self, surface: String, data: String) {
        self.notice("ui.update", json!({"surface": surface, "data": data}));
    }
    fn notify(&mut self, title: String, body: String) {
        self.notice("ui.notify", json!({"title": title, "body": body}));
    }
}

/// Compiles [wasm], or loads it from the cache when compiled before by this
/// same engine.
fn compile(engine: &Engine, wasm: &[u8], cache: Option<&Path>) -> Result<Component, String> {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    engine.precompile_compatibility_hash().hash(&mut hasher);
    let digest = Sha256::digest(wasm);
    let name = format!(
        "{}-{:016x}.cwasm",
        digest
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>(),
        hasher.finish()
    );
    let cached = cache.map(|c| c.join(name));
    if let Some(path) = &cached {
        if path.exists() {
            // Only this host writes the cache, from code it compiled itself.
            if let Ok(component) = unsafe { Component::deserialize_file(engine, path) } {
                return Ok(component);
            }
        }
    }
    let component = Component::new(engine, wasm).map_err(|e| format!("{e:#}"))?;
    if let (Some(path), Ok(bytes)) = (&cached, component.serialize()) {
        let _ = fs::create_dir_all(path.parent().unwrap_or(Path::new(".")));
        let next = path.with_extension("next");
        if fs::write(&next, bytes).is_ok() {
            let _ = fs::rename(&next, path);
        }
    }
    Ok(component)
}

/// Refuses a component that imports an interface it was not granted.
fn check_imports(engine: &Engine, component: &Component, grants: &[String]) -> Result<(), String> {
    for (name, _) in component.component_type().imports(engine) {
        let interface = name
            .strip_prefix("ournet:plugin/")
            .and_then(|rest| rest.split('@').next())
            .ok_or_else(|| format!("imports {name}, which OurNet does not provide"))?;
        if !ALWAYS.contains(&interface) && !grants.iter().any(|g| g == interface) {
            return Err(format!("uses {interface}, which it was not granted"));
        }
    }
    Ok(())
}

/// A running plugin: its store and instance, on its own thread.
struct Running {
    store: Store<Host>,
    plugin: Option<Plugin>,
    linker: Linker<Host>,
    grants: Vec<String>,
    cache: Option<PathBuf>,
}

impl Running {
    fn start(
        config: LoadConfig,
        wasm: &[u8],
        handle: u64,
        answers: Receiver<(u64, Vec<u8>)>,
        jobs: Sender<Job>,
        packets: Arc<AtomicUsize>,
    ) -> Result<Running, String> {
        let engine = engine()?;
        let component = compile(engine, wasm, config.cache.as_deref())?;
        check_imports(engine, &component, &config.grants)?;
        let mut linker = Linker::new(engine);
        Plugin::add_to_linker::<Host, HasSelf<Host>>(&mut linker, |h| h)
            .map_err(|e| e.to_string())?;
        let host = Host {
            handle,
            answers,
            next_question: 0,
            next_send: 0,
            limits: StoreLimitsBuilder::new()
                .memory_size(MEMORY_LIMIT)
                .instances(32)
                .tables(64)
                .memories(8)
                .build(),
            storage: Storage::open(config.dir.as_deref()),
            timers: BTreeMap::new(),
            call_began: Instant::now(),
            waited: Duration::ZERO,
            send_tokens: SEND_BURST,
            send_refill: Instant::now(),
            datagram_tokens: DATAGRAM_BURST,
            datagram_refill: Instant::now(),
            jobs,
            packets,
            tun: None,
        };
        let mut store = Store::new(engine, host);
        Self::configure(&mut store);
        let plugin =
            Plugin::instantiate(&mut store, &component, &linker).map_err(|e| format!("{e:#}"))?;
        Ok(Running {
            store,
            plugin: Some(plugin),
            linker,
            grants: config.grants,
            cache: config.cache,
        })
    }

    fn configure(store: &mut Store<Host>) {
        store.limiter(|h| &mut h.limits);
        store.set_epoch_deadline(1);
        store.epoch_deadline_callback(|ctx| {
            let host = ctx.data();
            let busy = host.call_began.elapsed().saturating_sub(host.waited);
            if busy > CALL_BUDGET {
                Err(wasmtime::Error::msg("plugin ran over its time budget"))
            } else {
                Ok(UpdateDeadline::Continue(10))
            }
        });
    }

    /// Runs [f] against the instance, counting its time; a trap stops the
    /// instance, since its state can no longer be trusted.
    fn run<R>(
        &mut self,
        f: impl FnOnce(&Plugin, &mut Store<Host>) -> wasmtime::Result<R>,
    ) -> Result<R, String> {
        let Some(plugin) = &self.plugin else {
            return Err("plugin stopped".into());
        };
        let host = self.store.data_mut();
        host.call_began = Instant::now();
        host.waited = Duration::ZERO;
        self.store.set_epoch_deadline(10);
        let result = f(plugin, &mut self.store);
        self.store.data_mut().storage.flush();
        result.map_err(|e| {
            let error = format!("{e:#}");
            self.plugin = None;
            post(
                self.store.data().handle,
                &json!({"type": "trap", "error": error}),
                None,
            );
            error
        })
    }

    /// Runs one call from Dart and posts its result.
    fn call(&mut self, message: &[u8]) {
        let (header, body) = split(message);
        let Ok(call) = serde_json::from_slice::<Value>(header) else {
            return;
        };
        let id = call.get("id").and_then(Value::as_u64).unwrap_or(0);
        let text = |k: &str| {
            call.get(k)
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string()
        };
        let mut reply_body = None;
        let result: Result<(), String> = match call.get("call").and_then(Value::as_str) {
            Some("init") => self.run(|p, s| p.call_init(s)),
            Some("objects") => {
                let objects: Vec<types::Object> = call
                    .get("objects")
                    .and_then(Value::as_array)
                    .map(|l| l.iter().filter_map(object_from).collect())
                    .unwrap_or_default();
                self.run(|p, s| p.call_on_objects(s, &objects))
            }
            Some("open") => {
                let (surface, context) = (text("surface"), text("context"));
                self.run(|p, s| p.call_on_open(s, &surface, &context))
            }
            Some("event") => {
                let (surface, name, args) = (text("surface"), text("name"), text("args"));
                self.run(|p, s| p.call_on_event(s, &surface, &name, &args))
            }
            Some("request") => {
                let device = text("device");
                match self.run(|p, s| p.call_on_request(s, &device, body)) {
                    Ok(Ok(bytes)) => {
                        reply_body = Some(bytes);
                        Ok(())
                    }
                    Ok(Err(refused)) => Err(refused),
                    Err(e) => Err(e),
                }
            }
            Some("reply") => {
                let request = call.get("request").and_then(Value::as_u64).unwrap_or(0);
                let error = call.get("error").and_then(Value::as_str).map(String::from);
                let reply = match &error {
                    Some(e) => Err(e.as_str()),
                    None => Ok(body),
                };
                self.run(|p, s| p.call_on_reply(s, request, reply))
            }
            // A packet into a memory interface, from Dart (tests).
            Some("packet") if self.store.data().tun.is_some() => {
                self.run(|p, s| p.call_on_packet(s, body))
            }
            Some("datagram") => {
                let device = text("device");
                self.run(|p, s| p.call_on_datagram(s, &device, body))
            }
            _ => Err("unknown call".into()),
        };
        // High-rate calls (datagrams) ask for no result unless they fail.
        if call.get("quiet").and_then(Value::as_bool) == Some(true) && result.is_ok() {
            return;
        }
        let header = match &result {
            Ok(()) => json!({"type": "result", "id": id}),
            Err(e) => json!({"type": "result", "id": id, "error": e}),
        };
        post(self.store.data().handle, &header, reply_body.as_deref());
    }

    /// Fires the timers that are due; returns how long until the next one.
    fn timers(&mut self) -> Option<Duration> {
        loop {
            let now = Instant::now();
            let next = self
                .store
                .data()
                .timers
                .iter()
                .min_by_key(|(_, due)| **due)
                .map(|(t, d)| (*t, *d));
            match next {
                Some((token, due)) if due <= now => {
                    self.store.data_mut().timers.remove(&token);
                    let _ = self.run(|p, s| p.call_on_timer(s, token));
                }
                Some((_, due)) => return Some(due - now),
                None => return None,
            }
            if self.plugin.is_none() {
                return None;
            }
        }
    }

    /// Swaps in a new version, handing it the old one's state.
    fn reload(&mut self, wasm: &[u8]) -> Result<(), String> {
        let engine = engine()?;
        let component = compile(engine, wasm, self.cache.as_deref())?;
        check_imports(engine, &component, &self.grants)?;
        let state = self.run(|p, s| p.call_save_state(s)).unwrap_or_default();
        let plugin = Plugin::instantiate(&mut self.store, &component, &self.linker)
            .map_err(|e| format!("{e:#}"))?;
        self.plugin = Some(plugin);
        self.run(|p, s| p.call_restore(s, &state))?;
        self.run(|p, s| p.call_init(s))
    }
}

fn run_plugin(
    handle: u64,
    config: LoadConfig,
    wasm: Vec<u8>,
    (jobs, queue): (Sender<Job>, Receiver<Job>),
    answers: Receiver<(u64, Vec<u8>)>,
) {
    let id = config.id.clone();
    let packets = Arc::new(AtomicUsize::new(0));
    let mut running = match Running::start(config, &wasm, handle, answers, jobs, packets.clone()) {
        Ok(r) => r,
        Err(error) => {
            post(handle, &json!({"type": "failed", "error": error}), None);
            return;
        }
    };
    drop(wasm);
    post(handle, &json!({"type": "loaded", "id": id}), None);
    loop {
        let next = running.timers();
        let job = match next {
            Some(wait) => queue.recv_timeout(wait),
            None => queue.recv().map_err(|_| RecvTimeoutError::Disconnected),
        };
        match job {
            Ok(Job::Call(message)) => running.call(&message),
            Ok(Job::Packet(packet)) => {
                packets.fetch_sub(1, Ordering::Relaxed);
                let _ = running.run(|p, s| p.call_on_packet(s, &packet));
            }
            Ok(Job::Reload(wasm)) => {
                let header = match running.reload(&wasm) {
                    Ok(()) => json!({"type": "loaded", "id": id, "reloaded": true}),
                    Err(error) => json!({"type": "failed", "error": error, "reloaded": true}),
                };
                post(handle, &header, None);
            }
            Err(RecvTimeoutError::Timeout) => {}
            Ok(Job::Stop) | Err(RecvTimeoutError::Disconnected) => break,
        }
    }
    let host = running.store.data_mut();
    host.storage.flush();
    if host.tun.take().is_some() {
        host.notice("tun.close", json!({}));
    }
}

unsafe fn bytes<'a>(data: *const u8, len: usize) -> &'a [u8] {
    if len == 0 || data.is_null() {
        &[]
    } else {
        std::slice::from_raw_parts(data, len)
    }
}

fn with_plugin<R>(handle: u64, f: impl FnOnce(&Handle) -> R) -> Option<R> {
    let plugins = PLUGINS.lock().ok()?;
    plugins.as_ref()?.get(&handle).map(f)
}

/// Sets the function results and imports are posted through. Returns the
/// host version, or 0 when plugins cannot run here (no engine for this CPU).
#[no_mangle]
pub unsafe extern "C" fn ournet_plugins_init(callback: Post) -> u32 {
    catch_unwind(|| {
        let _ = POST.set(callback);
        if engine().is_err() {
            return 0;
        }
        PLUGINS
            .lock()
            .map(|mut p| {
                p.get_or_insert_with(HashMap::new);
            })
            .ok();
        HOST_VERSION
    })
    .unwrap_or(0)
}

/// Starts a plugin from [wasm] with JSON [config] (see [LoadConfig]). It
/// compiles on its own thread and posts `loaded` or `failed`. Returns its
/// handle, or 0 for a config that does not parse.
#[no_mangle]
pub unsafe extern "C" fn ournet_plugin_load(
    config: *const u8,
    config_len: usize,
    wasm: *const u8,
    wasm_len: usize,
) -> u64 {
    let (config, wasm) = (
        bytes(config, config_len).to_vec(),
        bytes(wasm, wasm_len).to_vec(),
    );
    catch_unwind(move || {
        let Ok(config) = serde_json::from_slice::<LoadConfig>(&config) else {
            return 0;
        };
        let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
        let (jobs, job_queue) = mpsc::channel();
        let own_jobs = jobs.clone();
        let (answers, answer_queue) = mpsc::channel();
        let name = format!("ournet-plugin-{}", config.id);
        let started = thread::Builder::new()
            .name(name)
            .stack_size(8 << 20)
            .spawn(move || {
                let _ = catch_unwind(AssertUnwindSafe(|| {
                    run_plugin(handle, config, wasm, (own_jobs, job_queue), answer_queue)
                }));
            });
        if started.is_err() {
            return 0;
        }
        if let Ok(mut plugins) = PLUGINS.lock() {
            plugins
                .get_or_insert_with(HashMap::new)
                .insert(handle, Handle { jobs, answers });
        }
        handle
    })
    .unwrap_or(0)
}

/// Queues a call (a JSON line, optionally followed by bytes). 1 when queued.
#[no_mangle]
pub unsafe extern "C" fn ournet_plugin_call(handle: u64, message: *const u8, len: usize) -> i32 {
    let message = bytes(message, len).to_vec();
    with_plugin(handle, |h| h.jobs.send(Job::Call(message)).is_ok() as i32).unwrap_or(0)
}

/// Answers import [id] with JSON `{"ok": …}` or `{"error": …}`.
#[no_mangle]
pub unsafe extern "C" fn ournet_plugin_answer(
    handle: u64,
    id: u64,
    message: *const u8,
    len: usize,
) -> i32 {
    let message = bytes(message, len).to_vec();
    with_plugin(handle, |h| h.answers.send((id, message)).is_ok() as i32).unwrap_or(0)
}

/// Replaces the running plugin's code, keeping its state (hot reload).
#[no_mangle]
pub unsafe extern "C" fn ournet_plugin_reload(handle: u64, wasm: *const u8, len: usize) -> i32 {
    let wasm = bytes(wasm, len).to_vec();
    with_plugin(handle, |h| h.jobs.send(Job::Reload(wasm)).is_ok() as i32).unwrap_or(0)
}

/// Stops a plugin: its thread finishes the call in progress, saves its
/// storage and exits. Dart ignores anything still posted for it.
#[no_mangle]
pub unsafe extern "C" fn ournet_plugin_stop(handle: u64) -> i32 {
    let removed = PLUGINS.lock().ok().and_then(|mut p| p.as_mut()?.remove(&handle));
    match removed {
        Some(plugin) => {
            // Its interface's reader holds the queue open too.
            let _ = plugin.jobs.send(Job::Stop);
            1
        }
        None => 0,
    }
}
