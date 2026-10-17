use std::collections::BTreeMap;

use ournet_plugin::{device, json, store, timer, ui, Context, Plugin, Value};
#[path = "../../device-common.rs"]
mod common;

/// How long a controlling device counts as active after its last input.
const CONTROL_IDLE: u64 = 10_000;
/// How often the controller asks the chosen device what it accepts.
const STATUS_EVERY: u64 = 5_000;

#[derive(Default)]
struct RemoteInput {
    client: common::Client,
    /// Receiving side.
    receiving: bool,
    clipboard: bool,
    last_received: u64,
    received: u32,
    rate_at: u64,
    activity_at: u64,
    controllers: BTreeMap<String, u64>,
    /// Controlling side.
    text: String,
    movement: (i64, i64),
    queued: Option<Value>,
    tab: String,
    shown: u32,
    /// What the chosen device last said it accepts: (input, clipboard).
    remote: Option<(bool, bool)>,
    status_at: u64,
    status_request: Option<u64>,
}
const SURFACE: &str = "RemoteInput";
impl RemoteInput {
    fn show(&self) {
        self.client.show(SURFACE, false);
        let rows = common::devices();
        let names: Vec<_> = self.controllers.keys().map(|d| common::name_of(&rows, d)).collect();
        let (input_label, input_tone, clip_label, clip_tone) = match self.remote {
            _ if self.client.target.is_empty() => ("Mouse & keyboard", "off", "Clipboard", "off"),
            None => ("Mouse & keyboard: unknown", "off", "Clipboard: unknown", "off"),
            Some((input, clip)) => (
                if input { "Mouse & keyboard allowed" } else { "Mouse & keyboard off there" },
                if input { "ok" } else { "warn" },
                if clip { "Clipboard allowed" } else { "Clipboard off there" },
                if clip { "ok" } else { "warn" },
            ),
        };
        let (link_label, link_icon) = match self.client.link {
            _ if self.client.target.is_empty() => ("Not connected", "off"),
            // A routine status question is not news.
            common::Link::Waiting if self.status_request.is_some() && self.remote.is_some() => ("Connected", "ok"),
            common::Link::Idle => ("Ready", "ok"),
            common::Link::Waiting => ("Sending…", "send"),
            common::Link::Ok => ("Connected", "ok"),
            common::Link::Failed => ("Problem", "warning"),
        };
        ui::update(
            SURFACE,
            &json!({"text":self.text,
            "inputLabel":if self.receiving {"Disable incoming mouse / keyboard"}else{"Allow incoming mouse / keyboard"},
            "clipboardLabel":if self.clipboard {"Disable incoming clipboard"}else{"Allow incoming clipboard"},
            "receiving":self.receiving,"clipboard":self.clipboard,
            "receivingAny":self.receiving || self.clipboard,
            "receiveLabel":match (self.receiving, self.clipboard) {
                (true, true) => "Receiving mouse, keyboard and clipboard",
                (true, false) => "Receiving mouse and keyboard",
                (false, true) => "Receiving clipboard only",
                _ => "Not receiving",
            },
            "controlled":!self.controllers.is_empty(),
            "controlledLabel":if names.is_empty() {"Nobody is controlling this device".to_string()} else {format!("Being controlled by {}", names.join(", "))},
            "lastInput":if self.last_received==0 {"No incoming input this session".into()}else{format!("Last input {} seconds ago",ournet_plugin::now().saturating_sub(self.last_received)/1000)},
            "tab":if self.tab.is_empty() {"pad"} else {self.tab.as_str()},
            "linkLabel":link_label,"linkIcon":link_icon,
            "linkTone":match link_icon {"ok" => "ok", "off" => "off", "warning" => "danger", _ => "info"},
            "remoteInputLabel":input_label,"remoteInputTone":input_tone,
            "remoteClipLabel":clip_label,"remoteClipTone":clip_tone,
            "padHint":if self.client.target.is_empty() {"Choose a device above to use the touchpad"} else {"Drag to move · tap to click\nTwo fingers or the right edge: scroll · two-finger tap or hold: right-click"},
            "note":"Choose one of your devices running Remote Input, and allow incoming control there. Dictate with your phone keyboard's microphone."}),
        );
    }
    fn send(&mut self, v: Value) {
        self.movement = (0, 0);
        if self.client.pending.is_some() {
            if self.queued.is_none() {
                self.queued = Some(v);
            } else {
                self.client.status = "An action is already queued; wait for the device".into();
            }
        } else {
            self.client.send(&v);
        }
        timer::set(1, 33);
        self.show();
    }
    /// Keeps what this device accepts across launches.
    fn save(&self) {
        let _ = store::set_json("settings", &json!({"receiving":self.receiving,"clipboard":self.clipboard}));
    }
    /// Asks the chosen device what it accepts, between other requests.
    fn ask_status(&mut self) {
        if self.client.target.is_empty() || self.client.pending.is_some() {
            return;
        }
        self.status_at = ournet_plugin::now();
        self.client.send(&json!({"op":"status"}));
        self.status_request = self.client.pending.map(|p| p.0);
    }
}
impl Plugin for RemoteInput {
    fn init(&mut self) {
        let saved: Value = store::get_json("settings").unwrap_or_default();
        self.receiving = saved["receiving"] == true;
        self.clipboard = saved["clipboard"] == true;
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
                if !self.receiving && !self.clipboard {
                    self.controllers.clear();
                }
                self.save();
            }
            "clipboard" => {
                self.clipboard = args["value"].as_bool().unwrap_or(!self.clipboard);
                if !self.receiving && !self.clipboard {
                    self.controllers.clear();
                }
                self.save();
            }
            "disable" => {
                self.receiving = false;
                self.clipboard = false;
                self.controllers.clear();
                self.save();
            }
            "shown" => {
                self.shown = self.shown.saturating_add(1);
                self.ask_status();
            }
            "hidden" => self.shown = self.shown.saturating_sub(1),
            "tab" => self.tab = args["value"].as_str().unwrap_or("pad").into(),
            "select" => {
                let device = args["device"].as_str().or(args["value"].as_str()).unwrap_or("").to_string();
                self.client.select(&device);
                self.movement = (0, 0);
                self.queued = None;
                self.remote = None;
                self.ask_status();
            }
            "text" => {
                if let Some(t) = args["value"].as_str() {
                    if t.len() <= 16384 {
                        self.text = t.into();
                    } else {
                        self.client.status = "Text exceeds 16 KiB".into();
                    }
                }
            }
            "type" | "copy" | "paste" => {
                self.send(json!({"op":name,"text":self.text}));
            }
            "clear" => self.text.clear(),
            "key" => self.send(json!({"op":"key","key":args["key"]})),
            "click" => self.send(json!({"op":"click","button":args["button"]})),
            "scroll" => self.send(json!({"op":"scroll","amount":args["amount"]})),
            "move" => {
                // Coalesced here and sent from the timer, one request at a time.
                let dx = args["dx"].as_i64().unwrap_or(0);
                let dy = args["dy"].as_i64().unwrap_or(0);
                self.movement.0 = (self.movement.0 + dx).clamp(-2000, 2000);
                self.movement.1 = (self.movement.1 + dy).clamp(-2000, 2000);
                timer::set(1, 16);
                return;
            }
            _ => {}
        }
        self.show();
    }
    fn on_request(&mut self, from: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
        if !common::own(from) {
            return Err("Remote Input accepts only your own devices".into());
        }
        if payload.len() > 20_000 {
            return Err("Input too large".into());
        }
        let now = ournet_plugin::now();
        if now.saturating_sub(self.rate_at) >= 1000 {
            self.rate_at = now;
            self.received = 0;
        }
        self.received += 1;
        if self.received > 60 {
            return Err("Input rate exceeded".into());
        }
        let v: Value = serde_json::from_slice(payload).map_err(|_| "Invalid input")?;
        let op = v["op"].as_str().ok_or("Missing operation")?;
        if op == "status" {
            // Says only what this device accepts; touches nothing.
            return Ok(json!({"receiving":self.receiving,"clipboard":self.clipboard}).to_string().into_bytes());
        }
        if op == "copy" || op == "paste" {
            if !self.clipboard {
                return Err("Enable incoming clipboard on this device first".into());
            }
            if op == "paste" && !self.receiving {
                return Err("Enable incoming mouse / keyboard to paste".into());
            }
            device::copy(v["text"].as_str().ok_or("Missing text")?)?;
            if op == "paste" {
                device::input(&json!({"op":"paste"}))?;
            }
        } else {
            if !self.receiving {
                return Err("Enable incoming mouse / keyboard on this device first".into());
            }
            device::input(&v)?;
        }
        self.last_received = now;
        let first = !self.controllers.contains_key(from);
        self.controllers.insert(from.to_string(), now);
        if first {
            self.show();
        }
        // No clipboard/text content enters storage, logs or persistent objects.
        Ok(json!({"ok":true,"receiving":self.receiving,"clipboard":self.clipboard}).to_string().into_bytes())
    }
    fn on_reply(&mut self, id: u64, reply: Result<Vec<u8>, String>) {
        if self.client.pending.map(|p| p.0) != Some(id) {
            return;
        }
        let status = self.status_request.take() == Some(id);
        let answer = self.client.reply(id, reply);
        if let Some(v) = &answer {
            if let (Some(i), Some(c)) = (v["receiving"].as_bool(), v["clipboard"].as_bool()) {
                self.remote = Some((i, c));
            }
            if status {
                self.client.status = "Connected".into();
            }
        } else if status {
            self.remote = None;
            if self.client.status.contains("Unknown input operation")
                || self.client.status.contains("Enable incoming")
            {
                // An older receiver cannot say; its next real error will.
                self.client.link = common::Link::Idle;
                self.client.status = "Connected · an older version there cannot report its permissions".into();
            }
        }
        if answer.is_some() {
            if let Some(v) = self.queued.take() {
                self.client.send(&v);
            }
        } else {
            self.queued = None;
            self.movement = (0, 0);
        }
        self.show();
    }
    fn on_timer(&mut self, _: u64) {
        let now = ournet_plugin::now();
        let before = self.controllers.len();
        self.controllers.retain(|_, at| now.saturating_sub(*at) < CONTROL_IDLE);
        if before != self.controllers.len() {
            self.show();
        }
        if self.last_received != 0
            && now.saturating_sub(self.last_received) < 15_000
            && now.saturating_sub(self.activity_at) >= 1000
        {
            self.activity_at = now;
            ui::update(
                SURFACE,
                &json!({"lastInput":format!("Last input {} seconds ago",now.saturating_sub(self.last_received)/1000)}),
            );
        }
        let had_pending = self.client.pending.is_some();
        self.client.tick();
        if had_pending && self.client.pending.is_none() {
            self.movement = (0, 0);
            self.queued = None;
            self.status_request = None;
            self.show();
        }
        if self.movement != (0, 0) && self.client.pending.is_none() {
            let (dx, dy) = std::mem::take(&mut self.movement);
            self.client.send(&json!({"op":"move","dx":dx,"dy":dy}));
        } else if self.shown > 0 && now.saturating_sub(self.status_at) >= STATUS_EVERY {
            self.ask_status();
        }
        timer::set(
            1,
            if self.movement != (0, 0) || self.client.pending.is_some() {
                33
            } else {
                1000
            },
        );
    }
}
ournet_plugin::plugin!(RemoteInput);
