//! Remote Desktop: another of your devices' screen, or a friend's, with
//! mouse and keyboard (docs/REMOTE_DESKTOP.md). The host captures, encodes,
//! streams, decodes and injects input; this plugin keeps the receiving
//! switches, asks the chosen device to admit this one, and opens and closes
//! the view. A friend's request also asks the person at that device, each
//! time, in the app: this plugin cannot answer for them.
use std::collections::BTreeMap;

use ournet_plugin::{desktop, json, store, timer, ui, Context, Plugin, Value};
#[path = "../../device-common.rs"]
mod common;

const SURFACE: &str = "RemoteDesktop";
/// How long a viewing device counts as connected after it last asked.
const VIEWER_IDLE: u64 = 30_000;
/// How often the viewer asks the chosen device whether it accepts.
const STATUS_EVERY: u64 = 5_000;

/// Stream presets: label, then what the host is asked for.
const QUALITIES: [(&str, &str, u32, u32, u32); 4] = [
    ("fast", "Low latency · 720p 60 fps · 8 Mbit/s", 1280, 60, 8_000),
    ("balanced", "Balanced · 1080p 60 fps · 20 Mbit/s", 1920, 60, 20_000),
    ("sharp", "Sharp · 1440p 60 fps · 35 Mbit/s", 2560, 60, 35_000),
    ("native", "Native · up to 4K 60 fps · 60 Mbit/s", 3840, 60, 60_000),
];

#[derive(Default)]
struct RemoteDesktop {
    client: common::Client,
    /// Receiving side.
    receiving: bool,
    /// Friends may ask to connect (the person here still decides each time).
    friends: bool,
    viewers: BTreeMap<String, u64>,
    /// Viewing side.
    quality: String,
    session: Option<String>,
    /// The device the open view shows.
    viewing: String,
    /// A start asked for, awaiting the chosen device's answer.
    starting: bool,
    remote: Option<bool>,
    status_request: Option<u64>,
    status_at: u64,
    shown: u32,
}

impl RemoteDesktop {
    fn quality(&self) -> (&'static str, &'static str, u32, u32, u32) {
        QUALITIES
            .iter()
            .copied()
            .find(|q| q.0 == self.quality)
            .unwrap_or(QUALITIES[1])
    }

    fn show(&self) {
        self.client.show(SURFACE, false);
        let mut rows = common::devices();
        let friends = friend_devices();
        let mut options = common::Client::options(&rows, false);
        options.extend(friends.iter().map(|d| {
            json!({"value": d["id"], "label": d["name"], "detail": d["state"], "icon": "share"})
        }));
        rows.extend(friends);
        let names: Vec<_> = self.viewers.keys().map(|d| common::name_of(&rows, d)).collect();
        let target = rows.iter().find(|d| d["id"] == self.client.target.as_str());
        let (remote_label, remote_tone) = match self.remote {
            _ if self.client.target.is_empty() => ("Choose a device", "off"),
            None => ("Permission unknown", "off"),
            Some(true) => ("Remote desktop allowed there", "ok"),
            Some(false) => ("Remote desktop is off there", "warn"),
        };
        ui::update(
            SURFACE,
            &json!({
                "receiving": self.receiving,
                "viewed": !self.viewers.is_empty(),
                "viewedLabel": if names.is_empty() {
                    "Nobody is viewing this device".to_string()
                } else {
                    format!("Being viewed and controlled by {}", names.join(", "))
                },
                "receiveLabel": match (self.receiving, self.friends) {
                    (true, true) => "Allowing your devices, and friends who ask",
                    (true, false) => "Allowing your devices to connect",
                    _ => "Not accepting connections",
                },
                "friends": self.friends,
                "deviceOptions": options,
                "deviceLabel": match target {
                    Some(d) => d["name"].clone(),
                    None if self.client.target.is_empty() => json!("Choose a device"),
                    None => json!("Unavailable"),
                },
                "deviceDetail": match target {
                    Some(d) => d["state"].clone(),
                    None => json!(format!("{} devices available", rows.len())),
                },
                "viewing": self.session.is_some(),
                "session": self.session.clone().unwrap_or_default(),
                "viewingName": if self.viewing == ournet_plugin::this_device() {
                    "This device (preview)".to_string()
                } else {
                    common::name_of(&rows, &self.viewing)
                },
                "starting": self.starting,
                "canConnect": !self.client.target.is_empty() && !self.starting,
                "connectLabel": if self.starting { "Connecting…" } else { "Connect" },
                "remoteLabel": remote_label,
                "remoteTone": remote_tone,
                "quality": self.quality().0,
                "qualityLabel": self.quality().1,
                "qualityOptions": QUALITIES.iter().map(|q| json!({"value": q.0, "label": q.1})).collect::<Vec<_>>(),
            }),
        );
    }

    fn save(&self) {
        let _ = store::set_json(
            "settings",
            &json!({"receiving": self.receiving, "friends": self.friends, "quality": self.quality}),
        );
    }

    fn options(&self) -> Value {
        let (_, _, width, fps, kbps) = self.quality();
        json!({"width": width, "fps": fps, "kbps": kbps})
    }

    fn open(&mut self, device: &str) {
        self.close();
        match desktop::view(device, &self.options()) {
            Ok(session) => {
                self.session = Some(session);
                self.viewing = device.into();
                self.client.status = "Connected".into();
            }
            Err(e) => self.client.status = format!("Could not open the view: {e}"),
        }
    }

    fn close(&mut self) {
        if let Some(session) = self.session.take() {
            desktop::close(&session);
        }
    }

    /// Sends [value] to the chosen device, one request at a time. Unlike
    /// the device plugins' client, the device may be a friend's.
    fn send(&mut self, value: &Value) {
        if self.client.pending.is_some() || self.client.target.is_empty() {
            return;
        }
        let id = ournet_plugin::send(&self.client.target, value.to_string().as_bytes());
        self.client.pending = Some((id, ournet_plugin::now()));
        self.client.link = common::Link::Waiting;
        self.client.status = "Waiting for device…".into();
    }

    fn ask_status(&mut self) {
        if self.client.target.is_empty() || self.client.pending.is_some() {
            return;
        }
        self.status_at = ournet_plugin::now();
        self.send(&json!({"op": "status"}));
        self.status_request = self.client.pending.map(|p| p.0);
    }
}

impl Plugin for RemoteDesktop {
    fn init(&mut self) {
        let saved: Value = store::get_json("settings").unwrap_or_default();
        self.receiving = saved["receiving"] == true;
        self.friends = saved["friends"] == true;
        self.quality = saved["quality"].as_str().unwrap_or("balanced").into();
        timer::set(1, 1000);
        self.show();
    }

    fn on_open(&mut self, _: &str, _: Context) {
        self.show();
    }

    fn on_event(&mut self, _: &str, name: &str, args: Value) {
        match name {
            "receiving" => {
                self.receiving = args["value"].as_bool().unwrap_or(!self.receiving);
                if !self.receiving {
                    self.viewers.clear();
                }
                self.save();
            }
            "friends" => {
                self.friends = args["value"].as_bool().unwrap_or(!self.friends);
                self.save();
            }
            // From the remote-session banner's Stop.
            "disable" => {
                self.receiving = false;
                self.friends = false;
                self.viewers.clear();
                self.save();
            }
            "select" => {
                let device = args["value"].as_str().unwrap_or("").to_string();
                if common::own(&device) {
                    self.client.select(&device);
                } else if friend_devices().iter().any(|d| d["id"] == device.as_str()) {
                    self.client.target = device;
                    self.client.pending = None;
                    self.client.link = common::Link::Idle;
                    self.client.status = "Friend's device selected: they are asked each time".into();
                }
                self.remote = None;
                self.ask_status();
            }
            "quality" => {
                if let Some(q) = args["value"].as_str().filter(|q| QUALITIES.iter().any(|x| x.0 == *q)) {
                    self.quality = q.into();
                    self.save();
                }
            }
            "connect" => {
                if self.client.pending.is_some() {
                    // A status question is on its way; the start follows it.
                    self.starting = true;
                } else {
                    self.starting = true;
                    self.send(&json!({"op": "start"}));
                }
            }
            "preview" => {
                let this = ournet_plugin::this_device();
                self.open(&this);
            }
            "disconnect" => {
                self.close();
                self.client.status = "Disconnected".into();
            }
            "shown" => {
                self.shown = self.shown.saturating_add(1);
                self.ask_status();
            }
            "hidden" => self.shown = self.shown.saturating_sub(1),
            _ => {}
        }
        self.show();
    }

    fn on_request(&mut self, from: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
        let own = common::own(from);
        let accepts = self.receiving && (own || self.friends);
        let v: Value = serde_json::from_slice(payload).map_err(|_| "Invalid request")?;
        match v["op"].as_str() {
            // Says only whether this device accepts; touches nothing.
            Some("status") => Ok(json!({"receiving": accepts}).to_string().into_bytes()),
            Some("start") => {
                if !accepts {
                    return Err(if own || !self.receiving {
                        "Allow remote desktop on that device first"
                    } else {
                        "That device does not take requests from friends"
                    }
                    .into());
                }
                // For a friend, this waits while the person there decides.
                desktop::admit()?;
                let first = !self.viewers.contains_key(from);
                self.viewers.insert(from.to_string(), ournet_plugin::now());
                if first {
                    self.show();
                }
                Ok(json!({"ok": true, "receiving": true}).to_string().into_bytes())
            }
            _ => Err("Unknown request".into()),
        }
    }

    fn on_reply(&mut self, id: u64, reply: Result<Vec<u8>, String>) {
        if self.client.pending.map(|p| p.0) != Some(id) {
            return;
        }
        let status = self.status_request.take() == Some(id);
        let answer = self.client.reply(id, reply);
        if let Some(v) = &answer {
            if let Some(r) = v["receiving"].as_bool() {
                self.remote = Some(r);
            }
        }
        if status {
            if answer.is_none() {
                self.remote = None;
            } else {
                self.client.status = "Ready".into();
            }
            // A connect pressed while the question was out goes now.
            if self.starting {
                self.send(&json!({"op": "start"}));
            }
        } else if self.starting {
            self.starting = false;
            if answer.is_some() {
                let target = self.client.target.clone();
                self.open(&target);
            }
        }
        self.show();
    }

    fn on_timer(&mut self, _: u64) {
        let now = ournet_plugin::now();
        let before = self.viewers.len();
        self.viewers.retain(|_, at| now.saturating_sub(*at) < VIEWER_IDLE);
        let had_pending = self.client.pending.is_some();
        self.client.tick();
        if had_pending && self.client.pending.is_none() {
            self.starting = false;
            self.status_request = None;
            self.show();
        } else if before != self.viewers.len() {
            self.show();
        }
        if self.shown > 0 && self.session.is_none() && now.saturating_sub(self.status_at) >= STATUS_EVERY {
            self.ask_status();
        }
        timer::set(1, 1000);
    }

    fn save_state(&mut self) -> Vec<u8> {
        // A reload keeps the view open.
        json!({"session": self.session, "viewing": self.viewing, "target": self.client.target})
            .to_string()
            .into_bytes()
    }

    fn restore(&mut self, state: Vec<u8>) {
        let v: Value = serde_json::from_slice(&state).unwrap_or_default();
        self.session = v["session"].as_str().map(String::from);
        self.viewing = v["viewing"].as_str().unwrap_or("").into();
        if let Some(t) = v["target"].as_str() {
            self.client.select(t);
        }
    }
}

ournet_plugin::plugin!(RemoteDesktop);

/// Friends' devices running this plugin, for the device menu.
fn friend_devices() -> Vec<Value> {
    let me = ournet_plugin::me();
    ournet_plugin::contacts()
        .into_iter()
        .filter(|c| c.person != me)
        .flat_map(|c| {
            let person = if c.name.is_empty() { "A friend".to_string() } else { c.name.clone() };
            c.devices.into_iter().filter(|d| d.has_plugin).map(move |d| {
                let device = if d.name.is_empty() { d.id.chars().take(8).collect() } else { d.name };
                json!({"id": d.id, "name": format!("{person} · {device}"),
                    "state": if d.online {"Friend · online"} else {"Friend · not seen recently"}, "online": d.online})
            })
        })
        .collect()
}
