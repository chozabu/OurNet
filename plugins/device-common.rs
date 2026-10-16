//! Shared live-only device selection and bounded request bookkeeping.
use ournet_plugin::{json, ui, Value};

pub fn own(device: &str) -> bool {
    if device == ournet_plugin::this_device() {
        return true;
    }
    let me = ournet_plugin::me();
    ournet_plugin::contacts()
        .iter()
        .any(|c| c.person == me && c.devices.iter().any(|d| d.id == device))
}

pub fn devices() -> Vec<Value> {
    let me = ournet_plugin::me();
    let this = ournet_plugin::this_device();
    ournet_plugin::contacts().into_iter().filter(|c| c.person == me)
        .flat_map(|c| c.devices).filter(|d| d.id != this && d.has_plugin)
        .map(|d| json!({"id":d.id,"name":if d.name.is_empty() {d.id.chars().take(12).collect()} else {d.name},
            "state":if d.online {"Online"} else {"Not seen recently"}})).collect()
}

#[allow(dead_code)] // Shared source: only the dashboard formats byte counts.
pub fn bytes(n: f64) -> String {
    if n >= 1_073_741_824.0 {
        format!("{:.1} GiB", n / 1_073_741_824.0)
    } else if n >= 1_048_576.0 {
        format!("{:.1} MiB", n / 1_048_576.0)
    } else {
        format!("{:.1} KiB", n / 1024.0)
    }
}

#[derive(Default)]
pub struct Client {
    pub target: String,
    pub pending: Option<(u64, u64)>,
    pub status: String,
}
impl Client {
    pub fn select(&mut self, device: &str) {
        if own(device) {
            self.target = device.into();
            self.pending = None;
            self.status = "Device selected".into();
        }
    }
    pub fn send(&mut self, value: &Value) {
        if self.pending.is_some() {
            return;
        }
        if self.target.is_empty() || !own(&self.target) {
            self.status = "Choose one of your devices first".into();
            return;
        }
        let id = ournet_plugin::send(&self.target, value.to_string().as_bytes());
        self.pending = Some((id, ournet_plugin::now()));
        self.status = "Waiting for device…".into();
    }
    pub fn reply(&mut self, id: u64, reply: Result<Vec<u8>, String>) -> Option<Value> {
        if self.pending.map(|p| p.0) != Some(id) {
            return None;
        }
        self.pending = None;
        match reply.and_then(|b| serde_json::from_slice::<Value>(&b).map_err(|e| e.to_string())) {
            Ok(v) => {
                self.status = "Connected · updated just now".into();
                Some(v)
            }
            Err(e) => {
                self.status = format!("Device: {e}");
                None
            }
        }
    }
    pub fn tick(&mut self) {
        if self
            .pending
            .is_some_and(|(_, at)| ournet_plugin::now().saturating_sub(at) > 10_000)
        {
            self.pending = None;
            self.status = "Device did not answer; try again".into();
        }
    }
    pub fn show(&self, surface: &str) {
        let rows = devices();
        let target_name = if self.target.is_empty() {
            "Choose a device".to_owned()
        } else if self.target == ournet_plugin::this_device() {
            "Selected: This device".to_owned()
        } else {
            rows.iter()
                .find(|d| d["id"] == self.target)
                .and_then(|d| d["name"].as_str())
                .map(|name| format!("Selected: {name}"))
                .unwrap_or("Selected device is unavailable".into())
        };
        ui::update(
            surface,
            &json!({"devices":rows,"target":self.target,"targetName":target_name,"status":self.status,
            "busy":self.pending.is_some()}),
        );
    }
}
