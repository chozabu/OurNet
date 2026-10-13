//! Write OurNet plugins in Rust.
//!
//! A plugin is a type implementing [Plugin], exported with [plugin!]. The
//! host calls it on a thread of its own; everything here may block that
//! thread (asking the host to publish, say) but never the app.
//!
//! ```ignore
//! #[derive(Default)]
//! struct Hello;
//! impl ournet_plugin::Plugin for Hello {
//!     fn on_open(&mut self, surface: &str, _: ournet_plugin::Context) {
//!         ournet_plugin::ui::update(surface, &ournet_plugin::json!({"text": "Hello"}));
//!     }
//! }
//! ournet_plugin::plugin!(Hello);
//! ```

#[doc(hidden)]
pub mod bindings {
    wit_bindgen::generate!({
        path: "../../native/rust/wit",
        world: "plugin",
        pub_export_macro: true,
        default_bindings_module: "ournet_plugin::bindings",
    });
}

use bindings::ournet::plugin as host;

pub use bindings::ournet::plugin::identity::{Contact, Device, Group};
pub use bindings::ournet::plugin::types::{Audience, Object};
pub use serde_json::{self, json, Value};

/// A plugin. Every method has a default that does nothing, so a plugin
/// implements only what it uses. One value lives for as long as the plugin
/// runs; a hot reload hands its [Plugin::save_state] to the new version.
pub trait Plugin: Default + 'static {
    /// After loading, and after a hot reload's [Plugin::restore].
    fn init(&mut self) {}
    /// New objects of this plugin's kinds, each delivered once, in the order
    /// they were stored, including ones stored while it was not running.
    fn on_objects(&mut self, _objects: Vec<Object>) {}
    /// [surface] is being shown, in [context].
    fn on_open(&mut self, _surface: &str, _context: Context) {}
    /// A widget in [surface] fired [name] with [args].
    fn on_event(&mut self, _surface: &str, _name: &str, _args: Value) {}
    /// A live message from this plugin on a friend's [device]; the result is
    /// its reply.
    fn on_request(&mut self, _device: &str, _payload: &[u8]) -> Result<Vec<u8>, String> {
        Err("not handled".into())
    }
    /// The reply to [send] request [id].
    fn on_reply(&mut self, _id: u64, _reply: Result<Vec<u8>, String>) {}
    fn on_timer(&mut self, _token: u64) {}
    fn save_state(&mut self) -> Vec<u8> {
        Vec::new()
    }
    fn restore(&mut self, _state: Vec<u8>) {}
}

/// Where a surface was opened: the scope the app was showing.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Context {
    pub scope: Scope,
    /// The group's space, for [Scope::Group].
    pub space: Option<String>,
    /// The group's name, for [Scope::Group].
    pub name: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Scope {
    #[default]
    Personal,
    Group,
    Public,
}

impl Context {
    #[doc(hidden)]
    pub fn parse(json: &str) -> Context {
        let v: Value = serde_json::from_str(json).unwrap_or(Value::Null);
        let text = |k: &str| v.get(k).and_then(Value::as_str).map(String::from);
        Context {
            scope: match v.get("scope").and_then(Value::as_str) {
                Some("group") => Scope::Group,
                Some("public") => Scope::Public,
                _ => Scope::Personal,
            },
            space: text("space"),
            name: text("name"),
        }
    }
}

impl Object {
    /// The payload as JSON; `Null` if it does not parse.
    pub fn json(&self) -> Value {
        serde_json::from_str(&self.payload).unwrap_or(Value::Null)
    }
    /// The kind without its plugin prefix: `page` for `x.wiki.page`.
    pub fn name(&self) -> &str {
        self.kind.rsplit('.').next().unwrap_or(&self.kind)
    }
}

/// `x.<plugin>.<name>`: a kind or space in [plugin]'s namespace.
pub fn scoped(plugin: &str, name: &str) -> String {
    format!("x.{plugin}.{name}")
}

pub fn debug(message: &str) {
    host::log::log(host::log::Level::Debug, message);
}
pub fn info(message: &str) {
    host::log::log(host::log::Level::Info, message);
}
pub fn warn(message: &str) {
    host::log::log(host::log::Level::Warn, message);
}

/// Milliseconds since the epoch.
pub fn now() -> u64 {
    host::clock::now()
}

/// One-shot timers, delivered to [Plugin::on_timer].
pub mod timer {
    use super::host::clock;
    /// Calls `on_timer(token)` after [delay_ms]; setting a token again moves it.
    pub fn set(token: u64, delay_ms: u32) {
        clock::set_timer(token, delay_ms);
    }
    pub fn cancel(token: u64) {
        clock::cancel_timer(token);
    }
}

/// This plugin's private storage on this device.
pub mod store {
    use super::host::storage;
    use serde::{de::DeserializeOwned, Serialize};

    pub fn get(key: &str) -> Option<Vec<u8>> {
        storage::get(key)
    }
    pub fn set(key: &str, value: &[u8]) -> Result<(), String> {
        storage::set(key, value)
    }
    pub fn remove(key: &str) {
        storage::remove(key)
    }
    pub fn keys(prefix: &str) -> Vec<String> {
        storage::keys(prefix)
    }
    pub fn get_json<T: DeserializeOwned>(key: &str) -> Option<T> {
        serde_json::from_slice(&storage::get(key)?).ok()
    }
    pub fn set_json<T: Serialize>(key: &str, value: &T) -> Result<(), String> {
        storage::set(key, &serde_json::to_vec(value).map_err(|e| e.to_string())?)
    }
}

/// Signs, stores and syncs a new object. Returns its ID.
pub fn publish(kind: &str, space: &str, to: Audience, payload: &Value) -> Result<String, String> {
    host::objects::publish(kind, space, &to, &payload.to_string())
}

pub fn get(id: &str) -> Option<Object> {
    host::objects::get(id)
}

/// Objects of [kind], newest first: in [space] when given, older than
/// [before] (the last of a previous page) when given, [limit] at most.
pub fn query(kind: &str, space: Option<&str>, before: Option<&Object>, limit: u32) -> Vec<Object> {
    host::objects::query(&host::types::Filter {
        kind: kind.into(),
        space: space.map(String::from),
        author: None,
        before: before.map(|o| (o.created, o.id.clone())),
        limit,
    })
}

/// Follows a public space of this plugin's, so its objects are fetched.
pub fn follow(space: &str, on: bool) -> Result<(), String> {
    host::objects::follow(space, on)
}

/// This person.
pub fn me() -> String {
    host::identity::me()
}
/// This device.
pub fn this_device() -> String {
    host::identity::this_device()
}
pub fn contacts() -> Vec<Contact> {
    host::identity::contacts()
}
pub fn groups() -> Vec<Group> {
    host::identity::groups()
}

/// Sends a live message to this plugin on [device]. Returns the request ID
/// that [Plugin::on_reply] receives with the answer.
pub fn send(device: &str, payload: &[u8]) -> u64 {
    host::live::send(device, payload)
}

/// What the app shows.
pub mod ui {
    use super::{host, Value};
    /// Sets the top-level keys of [data] (an object) in what [surface]'s
    /// widgets read; a null value removes a key, others stay as they were.
    pub fn update(surface: &str, data: &Value) {
        host::ui::update(surface, &data.to_string());
    }
    pub fn notify(title: &str, body: &str) {
        host::ui::notify(title, body);
    }
}

/// Exports [Plugin] type `$t` as this component's implementation.
#[macro_export]
macro_rules! plugin {
    ($t:ty) => {
        struct __OurNetExport;

        ::std::thread_local! {
            static __OURNET_PLUGIN: ::core::cell::RefCell<$t> =
                ::core::cell::RefCell::new(<$t as ::core::default::Default>::default());
        }

        fn __ournet_with<R>(f: impl FnOnce(&mut $t) -> R) -> R {
            __OURNET_PLUGIN.with(|p| f(&mut p.borrow_mut()))
        }

        impl $crate::bindings::Guest for __OurNetExport {
            fn init() {
                __ournet_with(|p| $crate::Plugin::init(p))
            }
            fn on_objects(objects: ::std::vec::Vec<$crate::Object>) {
                __ournet_with(|p| $crate::Plugin::on_objects(p, objects))
            }
            fn on_open(surface: ::std::string::String, context: ::std::string::String) {
                __ournet_with(|p| $crate::Plugin::on_open(p, &surface, $crate::Context::parse(&context)))
            }
            fn on_event(
                surface: ::std::string::String,
                name: ::std::string::String,
                args: ::std::string::String,
            ) {
                let args = $crate::serde_json::from_str(&args).unwrap_or($crate::Value::Null);
                __ournet_with(|p| $crate::Plugin::on_event(p, &surface, &name, args))
            }
            fn on_request(
                device: ::std::string::String,
                payload: ::std::vec::Vec<u8>,
            ) -> ::core::result::Result<::std::vec::Vec<u8>, ::std::string::String> {
                __ournet_with(|p| $crate::Plugin::on_request(p, &device, &payload))
            }
            fn on_reply(
                id: u64,
                reply: ::core::result::Result<::std::vec::Vec<u8>, ::std::string::String>,
            ) {
                __ournet_with(|p| $crate::Plugin::on_reply(p, id, reply))
            }
            fn on_timer(token: u64) {
                __ournet_with(|p| $crate::Plugin::on_timer(p, token))
            }
            fn save_state() -> ::std::vec::Vec<u8> {
                __ournet_with(|p| $crate::Plugin::save_state(p))
            }
            fn restore(state: ::std::vec::Vec<u8>) {
                __ournet_with(|p| $crate::Plugin::restore(p, state))
            }
        }

        $crate::bindings::export!(__OurNetExport with_types_in $crate::bindings);
    };
}
