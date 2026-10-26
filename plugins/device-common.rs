//! Shared live-only device selection and bounded request bookkeeping.
use ournet_plugin::{json, ui, Value};

/// Whether [device] is this device or one certified to this person. The
/// host enforces the same for device capabilities; this check keeps the
/// plugin's own replies (and its errors) to the person's devices too.
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
            "state":if d.online {"Online"} else {"Not seen recently"},"online":d.online})).collect()
}

/// A device's name for showing, from a [devices] list.
pub fn name_of(rows: &[Value], device: &str) -> String {
    if device == ournet_plugin::this_device() {
        return "This device".into();
    }
    rows.iter()
        .find(|d| d["id"] == device)
        .and_then(|d| d["name"].as_str())
        .map(String::from)
        .unwrap_or_else(|| device.chars().take(12).collect())
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

/// Whether the latest reply succeeded, failed or is awaited.
#[derive(Default, Clone, Copy, PartialEq)]
pub enum Link {
    #[default]
    Idle,
    Waiting,
    Ok,
    Failed,
}

#[derive(Default)]
pub struct Client {
    pub target: String,
    pub pending: Option<(u64, u64)>,
    pub status: String,
    pub link: Link,
}
impl Client {
    pub fn select(&mut self, device: &str) {
        if own(device) {
            self.target = device.into();
            self.pending = None;
            self.link = Link::Idle;
            self.status = "Device selected".into();
        }
    }
    #[allow(dead_code)] // Remote Desktop sends to friends too, with its own.
    pub fn send(&mut self, value: &Value) {
        if self.pending.is_some() {
            return;
        }
        if self.target.is_empty() || !own(&self.target) {
            self.status = "Choose one of your devices first".into();
            self.link = Link::Idle;
            return;
        }
        let id = ournet_plugin::send(&self.target, value.to_string().as_bytes());
        self.pending = Some((id, ournet_plugin::now()));
        self.link = Link::Waiting;
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
                self.link = Link::Ok;
                Some(v)
            }
            Err(e) => {
                self.status = format!("Device: {e}");
                self.link = Link::Failed;
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
            self.link = Link::Failed;
            self.status = "Device did not answer; try again".into();
        }
    }
    /// The device picker's options: this device first when [local].
    pub fn options(rows: &[Value], local: bool) -> Vec<Value> {
        let mut options = Vec::new();
        if local {
            options.push(json!({"value":ournet_plugin::this_device(),"label":"This device",
                "detail":"Read here, without sharing","icon":"this"}));
        }
        options.extend(rows.iter().map(|d| {
            json!({"value":d["id"],"label":d["name"],"detail":d["state"],
                "icon":if d["online"] == true {"computer"} else {"devices"}})
        }));
        options
    }
    pub fn show(&self, surface: &str, local: bool) {
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
        let (label, detail) = if self.target.is_empty() {
            ("Choose a device".to_owned(), if rows.is_empty() {
                "None of your other devices runs this plugin yet".to_owned()
            } else {
                format!("{} of your devices available", rows.len())
            })
        } else {
            let row = rows.iter().find(|d| d["id"] == self.target);
            (
                name_of(&rows, &self.target),
                if self.target == ournet_plugin::this_device() {
                    "This device".into()
                } else {
                    row.and_then(|d| d["state"].as_str()).unwrap_or("Unavailable").into()
                },
            )
        };
        let tone = match self.link {
            Link::Idle => "off",
            Link::Waiting => "info",
            Link::Ok => "ok",
            Link::Failed => "danger",
        };
        ui::update(
            surface,
            &json!({"devices":rows,"target":self.target,"targetName":target_name,"status":self.status,
            "busy":self.pending.is_some(),"hasTarget":!self.target.is_empty(),
            "deviceOptions":Self::options(&rows, local),"deviceLabel":label,"deviceDetail":detail,
            "linkTone":tone}),
        );
    }
}
