//! The JavaScript runtime for script plugins (docs/SCRIPTING.md).
//!
//! A runtime is a plugin package marked `"provides": "runtime:js@1"`. The
//! host starts one instance of it for each script plugin, with that plugin's
//! grants, storage and kinds, and its `package` interface reads that
//! plugin's files. This crate runs the script's main module on Boa, gives it
//! the plugin API as `ournet`, and calls the handlers it exports.
//!
//! Most of `ournet` is written in JavaScript ([PRELUDE]) over a few native
//! functions (`__host`): the prelude turns `live.send` replies and timers
//! into promises, so a script may await them or ignore them.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use boa_engine::builtins::promise::PromiseState;
use boa_engine::context::time::JsInstant;
use boa_engine::context::{Clock, ContextBuilder};
use boa_engine::module::{ModuleLoader, Referrer};
use boa_engine::object::builtins::{JsArray, JsUint8Array};
use boa_engine::object::ObjectInitializer;
use boa_engine::property::Attribute;
use boa_engine::{
    js_string, Context, JsError, JsNativeError, JsObject, JsResult, JsString, JsValue, Module,
    NativeFunction, Source,
};
use ournet_plugin::{json, Audience, Context as Opened, Object, Plugin, Scope, Value};

/// The script run when the manifest names none.
const MAIN: &str = "scripts/main.js";

/// Builds `ournet` from `__host`; returns what the runtime calls back into.
const PRELUDE: &str = include_str!("prelude.js");

/// Script modules come from the plugin's package, under `scripts/`.
#[derive(Default)]
struct Loader {
    modules: RefCell<HashMap<String, Module>>,
}

impl Loader {
    fn load(&self, path: &str, context: &mut Context) -> JsResult<Module> {
        if let Some(module) = self.modules.borrow().get(path) {
            return Ok(module.clone());
        }
        if !path.starts_with("scripts/") || !path.ends_with(".js") {
            return Err(JsNativeError::typ()
                .with_message(format!("{path}: scripts live in scripts/ and end in .js"))
                .into());
        }
        let bytes = ournet_plugin::read(path)
            .ok_or_else(|| JsNativeError::typ().with_message(format!("{path}: not in the package")))?;
        let source = Source::from_bytes(&bytes).with_path(std::path::Path::new(path));
        let module = Module::parse(source, None, context)?;
        self.modules.borrow_mut().insert(path.into(), module.clone());
        Ok(module)
    }
}

/// `./x.js` and `../x.js` from the importing module, else from the package
/// root; never outside it.
fn resolve(specifier: &str, referrer: Option<&str>) -> Result<String, String> {
    let mut parts: Vec<&str> = Vec::new();
    if specifier.starts_with("./") || specifier.starts_with("../") {
        if let Some(r) = referrer {
            parts.extend(r.split('/'));
            parts.pop();
        }
    }
    for part in specifier.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop().ok_or_else(|| format!("{specifier}: outside the package"))?;
            }
            p => parts.push(p),
        }
    }
    Ok(parts.join("/"))
}

impl ModuleLoader for Loader {
    async fn load_imported_module(
        self: Rc<Self>,
        referrer: Referrer,
        request: boa_engine::module::ModuleRequest,
        context: &RefCell<&mut Context>,
    ) -> JsResult<Module> {
        let from = referrer.path().map(|p| p.to_string_lossy().replace('\\', "/"));
        let path = resolve(&request.specifier().to_std_string_escaped(), from.as_deref())
            .map_err(|e| JsError::from(JsNativeError::typ().with_message(e)))?;
        self.load(&path, &mut context.borrow_mut())
    }
}

/// Time from the host: plugins have no system clock of their own.
#[derive(Default)]
struct HostClock {
    latest: RefCell<u64>,
}

impl Clock for HostClock {
    fn now(&self) -> JsInstant {
        // Monotonic, as the engine requires, even if the wall clock steps back.
        let mut latest = self.latest.borrow_mut();
        *latest = (*latest).max(ournet_plugin::now());
        JsInstant::new(*latest / 1000, ((*latest % 1000) * 1_000_000) as u32)
    }
    fn system_time_millis(&self) -> i64 {
        ournet_plugin::now() as i64
    }
}

fn text(args: &[JsValue], i: usize, context: &mut Context) -> JsResult<String> {
    Ok(args.get(i).cloned().unwrap_or_default().to_string(context)?.to_std_string_escaped())
}

fn number(args: &[JsValue], i: usize, context: &mut Context) -> JsResult<f64> {
    args.get(i).cloned().unwrap_or_default().to_number(context)
}

fn bytes(args: &[JsValue], i: usize, context: &mut Context) -> JsResult<Vec<u8>> {
    let object = args
        .get(i)
        .and_then(JsValue::as_object)
        .ok_or_else(|| JsNativeError::typ().with_message("expected a Uint8Array"))?;
    JsUint8Array::from_object(object)?.to_vec(context)
}

fn byte_array(data: &[u8], context: &mut Context) -> JsResult<JsValue> {
    Ok(JsUint8Array::from_iter(data.iter().copied(), context)?.into())
}

fn json_arg(args: &[JsValue], i: usize, context: &mut Context) -> JsResult<Value> {
    Ok(args.get(i).cloned().unwrap_or_default().to_json(context)?.unwrap_or(Value::Null))
}

fn from_json(value: &Value, context: &mut Context) -> JsResult<JsValue> {
    JsValue::from_json(value, context)
}

fn fail(message: impl Into<String>) -> JsError {
    JsNativeError::error().with_message(message.into()).into()
}

/// An object as scripts see it: its fields, `name` (the kind without its
/// plugin prefix) and `data`, the payload parsed.
fn object_json(o: &Object) -> Value {
    json!({
        "id": o.id, "author": o.author, "device": o.device, "kind": o.kind, "name": o.name(),
        "space": o.space, "audience": o.audience, "created": o.created,
        "payload": o.payload, "data": o.json(),
    })
}

/// The native half of `ournet`. Each function is small: checking and
/// shaping arguments is the prelude's.
fn host_object(context: &mut Context) -> JsObject {
    type F = fn(&JsValue, &[JsValue], &mut Context) -> JsResult<JsValue>;
    let functions: &[(&str, usize, F)] = &[
        ("log", 2, |_, a, c| {
            let message = text(a, 1, c)?;
            match number(a, 0, c)? as u8 {
                0 => ournet_plugin::debug(&message),
                1 => ournet_plugin::info(&message),
                2 => ournet_plugin::warn(&message),
                _ => ournet_plugin::bindings::ournet::plugin::log::log(
                    ournet_plugin::bindings::ournet::plugin::log::Level::Error,
                    &message,
                ),
            }
            Ok(JsValue::undefined())
        }),
        ("now", 0, |_, _, _| Ok(JsValue::new(ournet_plugin::now() as f64))),
        ("setTimer", 2, |_, a, c| {
            ournet_plugin::timer::set(number(a, 0, c)? as u64, number(a, 1, c)?.clamp(0.0, u32::MAX as f64) as u32);
            Ok(JsValue::undefined())
        }),
        ("cancelTimer", 1, |_, a, c| {
            ournet_plugin::timer::cancel(number(a, 0, c)? as u64);
            Ok(JsValue::undefined())
        }),
        ("storageGet", 1, |_, a, c| match ournet_plugin::store::get(&text(a, 0, c)?) {
            Some(v) => byte_array(&v, c),
            None => Ok(JsValue::null()),
        }),
        ("storageSet", 2, |_, a, c| {
            ournet_plugin::store::set(&text(a, 0, c)?, &bytes(a, 1, c)?).map_err(fail)?;
            Ok(JsValue::undefined())
        }),
        ("storageRemove", 1, |_, a, c| {
            ournet_plugin::store::remove(&text(a, 0, c)?);
            Ok(JsValue::undefined())
        }),
        ("storageKeys", 1, |_, a, c| {
            let keys = ournet_plugin::store::keys(&text(a, 0, c)?);
            Ok(JsArray::from_iter(keys.into_iter().map(|k| JsValue::from(JsString::from(k))), c).into())
        }),
        ("publish", 4, |_, a, c| {
            let (kind, space) = (text(a, 0, c)?, text(a, 1, c)?);
            let to = match a.get(2).cloned().unwrap_or_default() {
                v if v.is_string() => match text(a, 2, c)?.as_str() {
                    "personal" => Audience::Personal,
                    "group" => Audience::Group,
                    "public" => Audience::Public,
                    other => return Err(fail(format!("unknown audience {other}"))),
                },
                _ => match json_arg(a, 2, c)? {
                    Value::Array(people) => Audience::People(
                        people.iter().filter_map(|p| p.as_str().map(String::from)).collect(),
                    ),
                    _ => return Err(fail("audience: personal, group, public or a list of people")),
                },
            };
            let payload = text(a, 3, c)?;
            let id = ournet_plugin::bindings::ournet::plugin::objects::publish(&kind, &space, &to, &payload)
                .map_err(fail)?;
            Ok(JsString::from(id).into())
        }),
        ("get", 1, |_, a, c| match ournet_plugin::get(&text(a, 0, c)?) {
            Some(o) => from_json(&object_json(&o), c),
            None => Ok(JsValue::null()),
        }),
        ("query", 1, |_, a, c| {
            let f = json_arg(a, 0, c)?;
            let s = |k: &str| f.get(k).and_then(Value::as_str).map(String::from);
            let filter = ournet_plugin::bindings::ournet::plugin::types::Filter {
                kind: s("kind").ok_or_else(|| fail("query: kind is needed"))?,
                space: s("space"),
                author: s("author"),
                before: f.get("before").and_then(|b| {
                    Some((b.get("created")?.as_u64()?, b.get("id")?.as_str()?.to_string()))
                }),
                limit: f.get("limit").and_then(Value::as_u64).unwrap_or(50).min(500) as u32,
            };
            let found: Vec<Value> = ournet_plugin::bindings::ournet::plugin::objects::query(&filter)
                .iter()
                .map(object_json)
                .collect();
            from_json(&Value::Array(found), c)
        }),
        ("follow", 2, |_, a, c| {
            let on = a.get(1).cloned().unwrap_or_default().to_boolean();
            ournet_plugin::follow(&text(a, 0, c)?, on).map_err(fail)?;
            Ok(JsValue::undefined())
        }),
        ("me", 0, |_, _, _| Ok(JsString::from(ournet_plugin::me()).into())),
        ("thisDevice", 0, |_, _, _| Ok(JsString::from(ournet_plugin::this_device()).into())),
        ("contacts", 0, |_, _, c| {
            let list: Vec<Value> = ournet_plugin::contacts()
                .into_iter()
                .map(|p| {
                    json!({
                        "person": p.person, "name": p.name,
                        "devices": p.devices.iter().map(|d| json!({
                            "id": d.id, "name": d.name, "online": d.online, "hasPlugin": d.has_plugin,
                        })).collect::<Vec<_>>(),
                    })
                })
                .collect();
            from_json(&Value::Array(list), c)
        }),
        ("groups", 0, |_, _, c| {
            let list: Vec<Value> = ournet_plugin::groups()
                .into_iter()
                .map(|g| json!({"space": g.space, "name": g.name, "members": g.members}))
                .collect();
            from_json(&Value::Array(list), c)
        }),
        ("send", 2, |_, a, c| {
            Ok(JsValue::new(ournet_plugin::send(&text(a, 0, c)?, &bytes(a, 1, c)?) as f64))
        }),
        ("datagram", 2, |_, a, c| {
            ournet_plugin::datagram(&text(a, 0, c)?, &bytes(a, 1, c)?).map_err(fail)?;
            Ok(JsValue::undefined())
        }),
        ("tunOpen", 4, |_, a, c| {
            let routes: Vec<String> = match json_arg(a, 2, c)? {
                Value::Array(r) => r.iter().filter_map(|r| r.as_str().map(String::from)).collect(),
                _ => Vec::new(),
            };
            let (prefix, mtu) = (number(a, 1, c)? as u8, number(a, 3, c)? as u16);
            ournet_plugin::tun::open(&text(a, 0, c)?, prefix, &routes, mtu).map_err(fail)?;
            Ok(JsValue::undefined())
        }),
        ("tunWrite", 1, |_, a, c| {
            ournet_plugin::tun::write(&bytes(a, 0, c)?);
            Ok(JsValue::undefined())
        }),
        ("tunClose", 0, |_, _, _| {
            ournet_plugin::tun::close();
            Ok(JsValue::undefined())
        }),
        ("update", 2, |_, a, c| {
            let surface = text(a, 0, c)?;
            let data = json_arg(a, 1, c)?;
            ournet_plugin::ui::update(&surface, &data);
            Ok(JsValue::undefined())
        }),
        ("notify", 2, |_, a, c| {
            ournet_plugin::ui::notify(&text(a, 0, c)?, &text(a, 1, c)?);
            Ok(JsValue::undefined())
        }),
        ("read", 1, |_, a, c| match ournet_plugin::read(&text(a, 0, c)?) {
            Some(v) => byte_array(&v, c),
            None => Ok(JsValue::null()),
        }),
        ("encode", 1, |_, a, c| byte_array(text(a, 0, c)?.as_bytes(), c)),
        ("decode", 1, |_, a, c| {
            Ok(JsString::from(String::from_utf8_lossy(&bytes(a, 0, c)?).as_ref()).into())
        }),
    ];
    let mut host = ObjectInitializer::new(context);
    for (name, length, f) in functions {
        host.function(NativeFunction::from_fn_ptr(*f), JsString::from(*name), *length);
    }
    host.build()
}

/// A script plugin, running.
struct Script {
    context: Context,
    /// The main module's exports: the handlers.
    exports: JsObject,
    /// From the prelude: `reply(id, bytes, error)` and `timer(token)`.
    internals: JsObject,
}

impl Script {
    fn start() -> Result<Script, String> {
        let loader = Rc::new(Loader::default());
        let mut context = ContextBuilder::default()
            .clock(Rc::new(HostClock::default()))
            .module_loader(loader.clone())
            .build()
            .map_err(|e| e.to_string())?;
        let host = host_object(&mut context);
        context
            .register_global_property(js_string!("__host"), host, Attribute::all())
            .map_err(|e| e.to_string())?;
        let internals = context
            .eval(Source::from_bytes(PRELUDE))
            .map_err(|e| describe(&e, &mut context))?
            .as_object()
            .ok_or("the prelude returned nothing")?;

        let manifest: Value = ournet_plugin::read("manifest.json")
            .and_then(|m| serde_json::from_slice(&m).ok())
            .unwrap_or(Value::Null);
        let main = manifest.get("main").and_then(Value::as_str).unwrap_or(MAIN).to_string();
        let module = loader.load(&main, &mut context).map_err(|e| describe(&e, &mut context))?;
        let promise = module.load_link_evaluate(&mut context);
        context.run_jobs().map_err(|e| describe(&e, &mut context))?;
        match promise.state() {
            PromiseState::Fulfilled(_) => {}
            PromiseState::Rejected(e) => return Err(describe(&JsError::from_opaque(e), &mut context)),
            // Top-level await on something that never comes.
            PromiseState::Pending => return Err(format!("{main} did not finish loading")),
        }
        let exports = module.namespace(&mut context);
        Ok(Script { context, exports, internals })
    }

    /// Calls the script's handler [name] if it exports one, then runs the
    /// promise jobs that call left. A handler that throws is logged; the
    /// plugin keeps running.
    fn call(&mut self, name: &str, args: &[JsValue]) -> Option<JsValue> {
        let handler = self.exports.get(JsString::from(name), &mut self.context).ok()?;
        let handler = handler.as_callable()?;
        let result = handler.call(&JsValue::undefined(), args, &mut self.context);
        self.settle();
        match result {
            Ok(v) => {
                // An async handler's error comes as a rejection, now or later.
                if v.as_promise().is_some() {
                    self.internal("watch", &[v.clone(), JsString::from(name).into()]);
                }
                Some(v)
            }
            Err(e) => {
                let message = describe(&e, &mut self.context);
                error(&format!("{name}: {message}"));
                None
            }
        }
    }

    fn internal(&mut self, name: &str, args: &[JsValue]) -> JsValue {
        let f = self.internals.get(JsString::from(name), &mut self.context).unwrap_or_default();
        let result = match f.as_callable() {
            Some(f) => f.call(&JsValue::undefined(), args, &mut self.context),
            None => Ok(JsValue::undefined()),
        };
        self.settle();
        result.unwrap_or_else(|e| {
            let message = describe(&e, &mut self.context);
            error(&message);
            JsValue::undefined()
        })
    }

    fn settle(&mut self) {
        if let Err(e) = self.context.run_jobs() {
            let message = describe(&e, &mut self.context);
            error(&message);
        }
    }

    fn json(&mut self, value: &Value) -> JsValue {
        JsValue::from_json(value, &mut self.context).unwrap_or_default()
    }

    fn bytes(&mut self, data: &[u8]) -> JsValue {
        byte_array(data, &mut self.context).unwrap_or_default()
    }

    /// What a handler returned, as bytes to send: a Uint8Array as it is,
    /// text as UTF-8, anything else as JSON; nothing as nothing.
    fn encode(&mut self, value: &JsValue) -> Vec<u8> {
        if value.is_undefined() {
            return Vec::new();
        }
        if let Some(object) = value.as_object() {
            if let Ok(array) = JsUint8Array::from_object(object) {
                return array.to_vec(&mut self.context).unwrap_or_default();
            }
        }
        if let Some(s) = value.as_string() {
            return s.to_std_string_escaped().into_bytes();
        }
        match value.to_json(&mut self.context) {
            Ok(Some(v)) => v.to_string().into_bytes(),
            _ => Vec::new(),
        }
    }
}

/// An error as a person reading the log wants it: the message, and where.
fn describe(error: &JsError, context: &mut Context) -> String {
    let Some(value) = error.as_opaque() else { return error.to_string() };
    let text = value
        .to_string(context)
        .map(|s| s.to_std_string_escaped())
        .unwrap_or_else(|_| error.to_string());
    // Boa's stack is the frames alone.
    match value.as_object().and_then(|o| o.get(js_string!("stack"), context).ok()) {
        Some(stack) if stack.is_string() => format!("{text}
{}", stack.display()),
        _ => text,
    }
}

fn error(message: &str) {
    use ournet_plugin::bindings::ournet::plugin::log;
    log::log(log::Level::Error, message);
}

#[derive(Default)]
struct Js {
    script: Option<Script>,
    /// From a hot reload's `restore`, for the script's `restore`.
    restored: Option<Vec<u8>>,
}

impl Js {
    fn script(&mut self) -> Option<&mut Script> {
        self.script.as_mut()
    }
}

impl Plugin for Js {
    fn init(&mut self) {
        if self.script.is_none() {
            match Script::start() {
                Ok(script) => self.script = Some(script),
                Err(e) => {
                    // Logged first: the trap that stops the plugin says little.
                    error(&e);
                    panic!("{e}");
                }
            }
        }
        let restored = self.restored.take();
        let script = self.script.as_mut().unwrap();
        if let Some(state) = restored {
            let value: Value = serde_json::from_slice(&state).unwrap_or(Value::Null);
            let value = script.json(&value);
            script.call("restore", &[value]);
        }
        script.call("init", &[]);
    }

    fn on_objects(&mut self, objects: Vec<Object>) {
        let Some(script) = self.script() else { return };
        let list = Value::Array(objects.iter().map(object_json).collect());
        let list = script.json(&list);
        script.call("onObjects", &[list]);
    }

    fn on_open(&mut self, surface: &str, context: Opened) {
        let Some(script) = self.script() else { return };
        let scope = match context.scope {
            Scope::Personal => "personal",
            Scope::Group => "group",
            Scope::Public => "public",
        };
        let opened = script.json(&json!({"scope": scope, "space": context.space, "name": context.name}));
        script.call("onOpen", &[JsString::from(surface).into(), opened]);
    }

    fn on_event(&mut self, surface: &str, name: &str, args: Value) {
        let Some(script) = self.script() else { return };
        let args = script.json(&args);
        script.call("onEvent", &[JsString::from(surface).into(), JsString::from(name).into(), args]);
    }

    fn on_request(&mut self, device: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
        let Some(script) = self.script() else { return Err("not running".into()) };
        let payload = script.bytes(payload);
        let handler = script
            .exports
            .get(js_string!("onRequest"), &mut script.context)
            .ok()
            .and_then(|h| h.as_callable())
            .ok_or("not handled")?;
        let result = handler.call(&JsValue::undefined(), &[JsString::from(device).into(), payload], &mut script.context);
        script.settle();
        let value = result.map_err(|e| describe(&e, &mut script.context))?;
        // An async handler answers once its promise settles; the reply cannot
        // wait for anything that comes later (another reply, a timer).
        let value = match value.as_promise() {
            Some(p) => match p.state() {
                PromiseState::Fulfilled(v) => v,
                PromiseState::Rejected(e) => return Err(describe(&JsError::from_opaque(e), &mut script.context)),
                PromiseState::Pending => return Err("the reply was not ready".into()),
            },
            None => value,
        };
        Ok(script.encode(&value))
    }

    fn on_reply(&mut self, id: u64, reply: Result<Vec<u8>, String>) {
        let Some(script) = self.script() else { return };
        let (bytes, error) = match &reply {
            Ok(b) => (script.bytes(b), JsValue::null()),
            Err(e) => (JsValue::null(), JsString::from(e.as_str()).into()),
        };
        let id = JsValue::new(id as f64);
        script.internal("reply", &[id.clone(), bytes.clone(), error.clone()]);
        script.call("onReply", &[id, bytes, error]);
    }

    fn on_timer(&mut self, token: u64) {
        let Some(script) = self.script() else { return };
        let token = JsValue::new(token as f64);
        // The prelude's own timers (sleep, setTimeout) are not the script's.
        if !script.internal("timer", &[token.clone()]).to_boolean() {
            script.call("onTimer", &[token]);
        }
    }

    fn on_datagram(&mut self, device: &str, data: &[u8]) {
        let Some(script) = self.script() else { return };
        let data = script.bytes(data);
        script.call("onDatagram", &[JsString::from(device).into(), data]);
    }

    fn on_packet(&mut self, packet: &[u8]) {
        let Some(script) = self.script() else { return };
        let packet = script.bytes(packet);
        script.call("onPacket", &[packet]);
    }

    fn save_state(&mut self) -> Vec<u8> {
        let Some(script) = self.script() else { return Vec::new() };
        match script.call("saveState", &[]) {
            Some(v) => match v.to_json(&mut script.context) {
                Ok(Some(v)) => v.to_string().into_bytes(),
                _ => Vec::new(),
            },
            None => Vec::new(),
        }
    }

    fn restore(&mut self, state: Vec<u8>) {
        if !state.is_empty() {
            self.restored = Some(state);
        }
    }
}

ournet_plugin::plugin!(Js);

/// The engine asks for random bytes (Math.random's seed, hash seeds). The
/// host has no random source for plugins, so they come from the clock and a
/// counter through splitmix64: unpredictable enough for games, never keys.
#[no_mangle]
unsafe extern "Rust" fn __getrandom_v03_custom(dest: *mut u8, len: usize) -> Result<(), getrandom::Error> {
    thread_local!(static STATE: std::cell::Cell<u64> = const { std::cell::Cell::new(0) });
    STATE.with(|state| {
        let mut s = state.get();
        if s == 0 {
            s = ournet_plugin::now() ^ 0x9E37_79B9_7F4A_7C15;
        }
        for i in 0..len {
            if i % 8 == 0 {
                s = s.wrapping_add(0x9E37_79B9_7F4A_7C15);
            }
            let mut z = s;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^= z >> 31;
            unsafe { *dest.add(i) = (z >> ((i % 8) * 8)) as u8 };
        }
        state.set(s);
    });
    Ok(())
}
