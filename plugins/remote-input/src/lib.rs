use ournet_plugin::{device, json, timer, ui, Context, Plugin, Value};
#[path = "../../device-common.rs"]
mod common;
#[derive(Default)]
struct RemoteInput {
    client: common::Client,
    receiving: bool,
    clipboard: bool,
    text: String,
    pointer: Option<(u64, f64, f64)>,
    movement: (i64, i64),
    last_received: u64,
    received: u32,
    rate_at: u64,
    activity_at: u64,
    queued: Option<Value>,
}
const SURFACE: &str = "RemoteInput";
impl RemoteInput {
    fn show(&self) {
        self.client.show(SURFACE);
        ui::update(
            SURFACE,
            &json!({"text":self.text,
            "inputLabel":if self.receiving {"Disable incoming mouse / keyboard"}else{"Allow incoming mouse / keyboard"},
            "clipboardLabel":if self.clipboard {"Disable incoming clipboard"}else{"Allow incoming clipboard"},
            "receiving":self.receiving,"clipboard":self.clipboard,
            "lastInput":if self.last_received==0 {"No incoming input this session".into()}else{format!("Last input {} seconds ago",ournet_plugin::now().saturating_sub(self.last_received)/1000)},
            "pad":[],"note":"Choose one of your devices running Remote Input. Enable receiving there. Dictate using your phone keyboard's microphone."}),
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
}
impl Plugin for RemoteInput {
    fn init(&mut self) {
        timer::set(1, 1000);
        self.show();
    }
    fn on_open(&mut self, _: &str, _: Context) {
        self.show();
    }
    fn on_event(&mut self, _: &str, name: &str, args: Value) {
        match name {
            "receiving" => self.receiving = !self.receiving,
            "clipboard" => self.clipboard = !self.clipboard,
            "disable" => {
                self.receiving = false;
                self.clipboard = false;
            }
            "select" => {
                self.client.select(args["device"].as_str().unwrap_or(""));
                self.pointer = None;
                self.movement = (0, 0);
                self.queued = None;
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
            "key" => self.send(json!({"op":"key","key":args["key"]})),
            "click" => self.send(json!({"op":"click","button":args["button"]})),
            "scroll" => self.send(json!({"op":"scroll","amount":args["amount"]})),
            "pointer" => {
                let id = args["pointer"].as_u64().unwrap_or(0);
                let x = args["x"].as_f64().unwrap_or(0.0);
                let y = args["y"].as_f64().unwrap_or(0.0);
                match args["phase"].as_str().unwrap_or("") {
                    "down" if self.pointer.is_none() => self.pointer = Some((id, x, y)),
                    "move" => {
                        if let Some((p, px, py)) = self.pointer {
                            if p == id {
                                self.movement.0 =
                                    (self.movement.0 + ((x - px) * 3.0) as i64).clamp(-2000, 2000);
                                self.movement.1 =
                                    (self.movement.1 + ((y - py) * 3.0) as i64).clamp(-2000, 2000);
                                self.pointer = Some((id, x, y));
                            }
                        }
                    }
                    "up" | "cancel" => {
                        if self.pointer.is_some_and(|p| p.0 == id) {
                            self.pointer = None;
                        }
                    }
                    _ => {}
                }
                timer::set(1, 33);
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
        // No clipboard/text content enters storage, logs or persistent objects.
        Ok(b"{\"ok\":true}".to_vec())
    }
    fn on_reply(&mut self, id: u64, reply: Result<Vec<u8>, String>) {
        if self.client.pending.map(|p| p.0) != Some(id) {
            return;
        }
        let ok = self.client.reply(id, reply).is_some();
        if ok {
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
            self.show();
        }
        if self.movement != (0, 0) && self.client.pending.is_none() {
            let (dx, dy) = std::mem::take(&mut self.movement);
            self.client.send(&json!({"op":"move","dx":dx,"dy":dy}));
        }
        timer::set(
            1,
            if self.pointer.is_some() || self.client.pending.is_some() {
                33
            } else {
                1000
            },
        );
    }
}
ournet_plugin::plugin!(RemoteInput);
