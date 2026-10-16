#![recursion_limit = "256"]
use std::collections::{BTreeMap, VecDeque};

use ournet_plugin::{device, json, timer, ui, Context, Plugin, Value};
#[path = "../../device-common.rs"]
mod common;
const SURFACE: &str = "Dashboard";

/// Samples kept per series: a minute at the default interval.
const HISTORY: usize = 60;
/// Cores drawn one by one at most.
const CORES: usize = 64;
/// Rows a reply carries, and rows an older controller is sent.
const ROWS: usize = 512;
const LEGACY_ROWS: usize = 128;
/// How long a remote viewer counts as watching after its last request.
const VIEWER_IDLE: u64 = 10_000;
/// Wait after a failed sample before trying again.
const BACKOFF: u64 = 5_000;

const CPU_COLOR: u32 = 0xff3f8fd8;
const MEMORY_COLOR: u32 = 0xff9b59d0;
const NETWORK_COLOR: u32 = 0xffd08a2e;
const SENT_COLOR: u32 = 0xff2ea89b;
const DISK_COLOR: u32 = 0xff4caf50;
const WRITE_COLOR: u32 = 0xffe0607e;
const HEAT_COLOR: u32 = 0xffe05a47;

/// A fixed-size rolling series.
#[derive(Default)]
struct Series(VecDeque<f64>);
impl Series {
    fn push(&mut self, v: Option<f64>) {
        if let Some(v) = v {
            if self.0.len() == HISTORY {
                self.0.pop_front();
            }
            self.0.push_back(v);
        }
    }
    fn json(&self) -> Value {
        json!(self.0.iter().map(|v| (v * 10.0).round() / 10.0).collect::<Vec<_>>())
    }
    fn max(&self) -> f64 {
        self.0.iter().cloned().fold(0.0, f64::max)
    }
}

#[derive(Clone)]
struct Process {
    pid: u64,
    started: u64,
    name: String,
    cpu: f64,
    memory: f64,
    read: Option<f64>,
    write: Option<f64>,
}

#[derive(Default)]
struct Dashboard {
    client: common::Client,
    /// Receiving side: may other devices read this one, and end processes.
    sharing: bool,
    control: bool,
    viewers: BTreeMap<String, u64>,
    /// Controlling side.
    shown: u32,
    paused: bool,
    interval: u64,
    next_at: u64,
    tab: String,
    focus: String,
    report: Value,
    processes: Vec<Process>,
    selected: Option<Process>,
    confirming: bool,
    /// A confirmed end waiting for the request before it, and the request
    /// ending one.
    stop_after: Option<Process>,
    stop_request: Option<u64>,
    notice: String,
    cpu: Series,
    cores: Vec<Series>,
    memory: Series,
    received: Series,
    sent: Series,
    read: Series,
    write: Series,
    disk: Series,
}

fn rate(n: f64) -> String {
    format!("{}/s", common::bytes(n))
}

fn duration(seconds: u64) -> String {
    let (d, h, m) = (seconds / 86_400, seconds / 3600 % 24, seconds / 60 % 60);
    if d > 0 {
        format!("{d} d {h} h {m} min")
    } else {
        format!("{h} h {m} min")
    }
}

fn count(v: &Value) -> String {
    v.as_u64().map(|n| n.to_string()).unwrap_or("—".into())
}

impl Dashboard {
    fn interval(&self) -> u64 {
        if self.interval == 0 { 1000 } else { self.interval }
    }
    /// Whether samples stream now: someone is looking, a device is chosen
    /// and they have not paused it.
    fn live(&self) -> bool {
        self.shown > 0 && !self.paused && !self.client.target.is_empty() && !self.confirming
    }
    fn local(&self) -> bool {
        self.client.target == ournet_plugin::this_device()
    }
    fn cores(&self) -> f64 {
        self.report["cores"].as_f64().filter(|n| *n >= 1.0).unwrap_or(1.0)
    }

    fn show(&self) {
        self.client.show(SURFACE, true);
        let v = &self.report;
        let has = !v.is_null();
        let n = |k: &str| v[k].as_f64();
        let memory_total = n("memoryTotal").unwrap_or(0.0);
        let memory_used = n("memoryUsed").unwrap_or(0.0);
        let percent = |a: f64, b: f64| if b > 0.0 { a / b * 100.0 } else { 0.0 };
        let cpu_value = n("cpu").map(|c| format!("{c:.0}%")).unwrap_or("Sampling…".into());
        // Short values, so a phone's two columns fit them.
        let (net_value, net_detail) = match (n("receivedPerSecond"), n("sentPerSecond")) {
            (Some(r), Some(s)) => (format!("↓ {}", rate(r)), format!("↑ {} · all adapters", rate(s))),
            _ => ("Sampling…".into(), "Receive and send, all adapters".into()),
        };
        let volumes = v["disks"].as_array().map(|d| d.len()).unwrap_or(0);
        let (disk_value, disk_detail) = match (n("diskReadPerSecond"), n("diskWritePerSecond")) {
            (Some(r), Some(w)) => (rate(r + w), format!("Read {} · write {}", rate(r), rate(w))),
            _ if v["disks"].is_array() => ("Sampling…".into(), format!("{volumes} volumes")),
            _ => ("Unavailable".into(), String::new()),
        };
        let temps: Vec<_> = v["temperatures"].as_array().cloned().unwrap_or_default();
        let hottest = temps.iter().filter_map(|t| t["celsius"].as_f64()).fold(f64::NAN, f64::max);
        let net_max = self.received.max().max(self.sent.max()).max(1024.0);
        let disk_max = self.read.max().max(self.write.max()).max(1024.0);
        let mut tiles = vec![
            json!({"key":"cpu","label":"CPU","icon":"cpu","value":cpu_value,"color":CPU_COLOR,
                "detail":n("cpuFrequency").map(|f| format!("{:.2} GHz", f / 1000.0)).unwrap_or_default(),
                "values":self.cpu.json(),"max":100}),
            json!({"key":"memory","label":"Memory","icon":"memory","color":MEMORY_COLOR,
                "value":format!("{:.0}%", percent(memory_used, memory_total)),
                "detail":format!("{} of {}", common::bytes(memory_used), common::bytes(memory_total)),
                "values":self.memory.json(),"max":100}),
            json!({"key":"network","label":"Network","icon":"network","color":NETWORK_COLOR,
                "value":net_value,"detail":net_detail,
                "values":self.received.json(),"max":net_max}),
            json!({"key":"disk","label":"Disk","icon":"disk","color":DISK_COLOR,"value":disk_value,
                "detail":disk_detail,"values":self.disk.json(),"max":self.disk.max().max(1024.0)}),
        ];
        if !temps.is_empty() {
            tiles.push(json!({"key":"temperature","label":"Temperature","icon":"temperature",
                "color":HEAT_COLOR,"value":format!("{hottest:.0} °C"),
                "detail":format!("Hottest of {} sensors", temps.len()),"values":[]}));
        }
        let focus = if self.focus.is_empty() { "cpu" } else { self.focus.as_str() };
        let tiles: Vec<_> = tiles
            .into_iter()
            .map(|mut t| {
                t["selected"] = json!(t["key"] == focus);
                t
            })
            .collect();
        let stat = |label: &str, value: String| json!({"label":label,"value":value});
        let (title, subtitle, chart, chart_max, top, stats): (&str, String, Vec<Value>, f64, String, Vec<Value>) = match focus {
            "memory" => (
                "Memory",
                format!("{} total", common::bytes(memory_total)),
                vec![json!({"values":self.memory.json(),"color":MEMORY_COLOR})],
                100.0,
                "100%".into(),
                vec![
                    stat("In use", common::bytes(memory_used)),
                    stat("Available", n("memoryAvailable").map(common::bytes).unwrap_or("—".into())),
                    stat("Committed", match (n("commitUsed"), n("commitLimit")) {
                        (Some(a), Some(b)) => format!("{} / {}", common::bytes(a), common::bytes(b)),
                        _ => "—".into(),
                    }),
                    stat("Swap", match (n("swapUsed"), n("swapTotal")) {
                        (Some(a), Some(b)) if b > 0.0 => format!("{} / {}", common::bytes(a), common::bytes(b)),
                        _ => "—".into(),
                    }),
                ],
            ),
            "network" => (
                "Network",
                "All adapters".into(),
                vec![
                    json!({"values":self.received.json(),"color":NETWORK_COLOR}),
                    json!({"values":self.sent.json(),"color":SENT_COLOR,"fill":false}),
                ],
                net_max * 1.1,
                rate(net_max),
                vec![
                    stat("Receive", n("receivedPerSecond").map(rate).unwrap_or("—".into())),
                    stat("Send", n("sentPerSecond").map(rate).unwrap_or("—".into())),
                ],
            ),
            "disk" => (
                "Disk",
                "All volumes".into(),
                vec![
                    json!({"values":self.read.json(),"color":DISK_COLOR}),
                    json!({"values":self.write.json(),"color":WRITE_COLOR,"fill":false}),
                ],
                disk_max * 1.1,
                rate(disk_max),
                vec![
                    stat("Read", n("diskReadPerSecond").map(rate).unwrap_or("—".into())),
                    stat("Write", n("diskWritePerSecond").map(rate).unwrap_or("—".into())),
                ],
            ),
            "temperature" => (
                "Temperature",
                "Sensors the system exposes".into(),
                vec![],
                100.0,
                String::new(),
                temps
                    .iter()
                    .map(|t| stat(t["name"].as_str().unwrap_or("Sensor"), format!("{:.1} °C", t["celsius"].as_f64().unwrap_or(0.0))))
                    .collect(),
            ),
            _ => (
                "CPU",
                v["cpuBrand"].as_str().unwrap_or("").to_string(),
                vec![json!({"values":self.cpu.json(),"color":CPU_COLOR})],
                100.0,
                "100%".into(),
                vec![
                    stat("Utilisation", n("cpu").map(|c| format!("{c:.0}%")).unwrap_or("—".into())),
                    stat("Speed", n("cpuFrequency").map(|f| format!("{:.2} GHz", f / 1000.0)).unwrap_or("—".into())),
                    stat("Processes", count(&v["processCount"])),
                    stat("Threads", count(&v["threadCount"])),
                    stat("Handles", count(&v["handleCount"])),
                    stat("Up time", n("uptime").map(|u| duration(u as u64)).unwrap_or("—".into())),
                    stat("Logical processors", count(&v["cores"])),
                    stat("Cores", count(&v["physicalCores"])),
                ],
            ),
        };
        let cores: Vec<_> = if focus == "cpu" {
            self.cores
                .iter()
                .enumerate()
                .map(|(i, s)| json!({"label":format!("CPU {i}"),"values":s.json(),
                    "value":s.0.back().map(|c| format!("{c:.0}%")).unwrap_or_default()}))
                .collect()
        } else {
            Vec::new()
        };
        let disks: Vec<_> = if focus == "disk" {
            v["disks"].as_array().into_iter().flatten().map(|d| {
                let total = d["total"].as_f64().unwrap_or(0.0);
                let used = total - d["available"].as_f64().unwrap_or(0.0);
                json!({"name":format!("{} {}", d["mount"].as_str().unwrap_or(""), d["kind"].as_str().unwrap_or("")),
                    "detail":format!("{} free of {} · R {} W {}", common::bytes(total - used), common::bytes(total),
                        d["readPerSecond"].as_f64().map(rate).unwrap_or("—".into()),
                        d["writePerSecond"].as_f64().map(rate).unwrap_or("—".into())),
                    "used":if total > 0.0 { used / total } else { 0.0 }})
            }).collect()
        } else {
            Vec::new()
        };
        let cores_n = self.cores();
        let rows: Vec<_> = self.processes.iter().map(|p| {
            let cpu = p.cpu / cores_n;
            let disk = p.read.unwrap_or(0.0) + p.write.unwrap_or(0.0);
            json!({"id":p.pid,"cells":[p.name, p.pid.to_string(), format!("{cpu:.1}%"), common::bytes(p.memory),
                if p.read.is_some() { rate(disk) } else { "—".into() }],
                "keys":[p.name, p.pid, cpu, p.memory, disk]})
        }).collect();
        let viewers: Vec<_> = self.viewers.keys().cloned().collect();
        let viewer_rows = common::devices();
        let viewer_names: Vec<_> = viewers.iter().map(|d| common::name_of(&viewer_rows, d)).collect();
        let (live_label, live_tone, live_icon) = if self.client.target.is_empty() {
            ("Not watching", "off", "pause")
        } else if self.confirming {
            ("Paused to confirm", "warn", "pause")
        } else if self.paused {
            ("Paused", "warn", "pause")
        } else if self.shown == 0 {
            ("Stopped", "off", "pause")
        } else if self.client.link == common::Link::Failed {
            ("Retrying", "danger", "warning")
        } else {
            ("Live", "ok", "visible")
        };
        let interval_label = match self.interval() {
            1000 => "Every 1 s",
            2000 => "Every 2 s",
            _ => "Every 5 s",
        };
        let selected = self.selected.as_ref();
        ui::update(
            SURFACE,
            &json!({"sharing":self.sharing,"control":self.control,
            "watching":self.live(),"paused":self.paused,
            "shareLabel":if self.sharing {"Stop sharing this device"}else{"Share this device's metrics"},
            "controlLabel":if self.control {"Disable process control"}else{"Allow ending processes"},
            "liveLabel":live_label,"liveTone":live_tone,"liveIcon":live_icon,
            "pauseLabel":if self.paused {"Resume"} else {"Pause"},"pauseIcon":if self.paused {"play"} else {"pause"},
            "intervalLabel":interval_label,"interval":self.interval().to_string(),
            "tab":if self.tab.is_empty() {"performance"} else {self.tab.as_str()},
            "tiles":tiles,"focus":focus,"focusTitle":title,"focusSubtitle":subtitle,
            "chart":chart,"chartMax":chart_max,"chartTop":top,"stats":stats,
            "cores":cores,"hasCores":!cores.is_empty(),"disks":disks,"hasDisks":!disks.is_empty(),
            "hasReport":has,"rows":rows,
            "processCount":format!("{} processes{}", v["processCount"].as_u64().map(|n| n as usize).unwrap_or(self.processes.len()),
                if self.processes.len() >= ROWS { format!(" · {ROWS} busiest shown") } else { String::new() }),
            "selectedPid":selected.map(|p| p.pid),
            "hasSelection":selected.is_some(),
            "selectedLabel":selected.map(|p| format!("{} · PID {}", p.name, p.pid)).unwrap_or("Select a process to end it".into()),
            "confirming":self.confirming,
            "confirmName":selected.map(|p| p.name.clone()).unwrap_or_default(),
            "confirmText":selected.map(|p| format!("End {} (PID {}) on {}? Unsaved work in it may be lost.", p.name, p.pid,
                if self.local() {"this device".to_string()} else {common::name_of(&viewer_rows, &self.client.target)})).unwrap_or_default(),
            "notice":self.notice,"hasNotice":!self.notice.is_empty(),
            "viewed":!viewers.is_empty(),
            "viewedLabel":if viewers.is_empty() {"Nobody is viewing this device".to_string()} else {format!("Being viewed by {}", viewer_names.join(", "))},
            "sensorNote":"GPU load and fan speed are unavailable. Temperatures appear only when the system exposes them.",
            // Earlier interfaces' keys, still read by tests.
            "metrics":tiles_compat(v),"processes":self.processes.iter().take(LEGACY_ROWS).map(|p| json!({"pid":p.pid,"started":p.started,"name":p.name})).collect::<Vec<_>>(),
            }),
        );
    }

    fn sample(&mut self) {
        self.next_at = ournet_plugin::now() + self.interval();
        let processes = self.tab == "processes";
        self.dispatch(json!({"op":"snapshot","processes":processes,"v":2}));
    }

    fn dispatch(&mut self, v: Value) {
        if self.local() {
            match self.on_request(&ournet_plugin::this_device(), v.to_string().as_bytes()) {
                Ok(bytes) => {
                    if let Ok(v) = serde_json::from_slice(&bytes) {
                        self.accept(v);
                        self.client.link = common::Link::Ok;
                        self.client.status = "This device".into();
                    }
                }
                Err(e) => {
                    self.client.link = common::Link::Failed;
                    self.client.status = e;
                }
            }
        } else {
            self.client.send(&v);
        }
    }

    fn accept(&mut self, mut v: Value) {
        self.cpu.push(v["cpu"].as_f64().map(|n| n.clamp(0.0, 100.0)));
        if let Some(cores) = v["perCore"].as_array() {
            self.cores.resize_with(cores.len().min(CORES), Series::default);
            for (s, c) in self.cores.iter_mut().zip(cores) {
                s.push(c.as_f64().map(|n| n.clamp(0.0, 100.0)));
            }
        }
        let total = v["memoryTotal"].as_f64().unwrap_or(0.0);
        if total > 0.0 {
            self.memory.push(v["memoryUsed"].as_f64().map(|u| u / total * 100.0));
        }
        self.received.push(v["receivedPerSecond"].as_f64());
        self.sent.push(v["sentPerSecond"].as_f64());
        self.read.push(v["diskReadPerSecond"].as_f64());
        self.write.push(v["diskWritePerSecond"].as_f64());
        if let (Some(r), Some(w)) = (v["diskReadPerSecond"].as_f64(), v["diskWritePerSecond"].as_f64()) {
            self.disk.push(Some(r + w));
        }
        let parsed: Option<Vec<Process>> = if let Some(rows) = v["processRows"].as_array() {
            Some(rows.iter().filter_map(|r| Some(Process {
                pid: r[0].as_u64()?, started: r[1].as_u64()?, name: r[2].as_str()?.into(),
                cpu: r[3].as_f64().unwrap_or(0.0), memory: r[4].as_f64().unwrap_or(0.0),
                read: r[5].as_f64(), write: r[6].as_f64(),
            })).collect())
        } else {
            v["processes"].as_array().map(|rows| rows.iter().filter_map(|p| Some(Process {
                pid: p["pid"].as_u64()?, started: p["started"].as_u64()?, name: p["name"].as_str()?.into(),
                cpu: p["cpu"].as_f64().unwrap_or(0.0), memory: p["memory"].as_f64().unwrap_or(0.0),
                read: p["diskRead"].as_f64(), write: p["diskWrite"].as_f64(),
            })).collect())
        };
        if let Some(rows) = parsed {
            self.processes = rows;
            // A selection stays only while that very process is listed.
            if let Some(s) = &self.selected {
                self.selected = self.processes.iter().find(|p| p.pid == s.pid && p.started == s.started).cloned();
                if self.selected.is_none() {
                    self.confirming = false;
                }
            }
        }
        if let Some(o) = v.as_object_mut() {
            o.remove("processes");
            o.remove("processRows");
        }
        self.report = v;
    }

    fn end(&mut self, p: Process) {
        self.dispatch(json!({"op":"stop","pid":p.pid,"started":p.started,"v":2}));
        if self.local() {
            self.notice = if self.client.link == common::Link::Failed {
                self.client.status.clone()
            } else {
                format!("Ended {}", p.name)
            };
        } else {
            self.stop_request = self.client.pending.map(|r| r.0);
        }
    }

    fn reset(&mut self) {
        self.report = Value::Null;
        self.processes.clear();
        self.selected = None;
        self.confirming = false;
        self.stop_after = None;
        self.stop_request = None;
        self.notice.clear();
        for s in [&mut self.cpu, &mut self.memory, &mut self.received, &mut self.sent, &mut self.read, &mut self.write, &mut self.disk] {
            s.0.clear();
        }
        self.cores.clear();
    }

    fn choose(&mut self, device: &str) {
        if device == ournet_plugin::this_device() {
            self.client.target = device.into();
            self.client.pending = None;
            self.client.link = common::Link::Idle;
        } else {
            self.client.select(device);
        }
        self.reset();
        self.paused = false;
        self.sample();
    }
}

/// The figures the first interface listed, by name.
fn tiles_compat(v: &Value) -> Vec<Value> {
    if v.is_null() {
        return Vec::new();
    }
    vec![json!({"name":"CPU"}), json!({"name":"Memory"}), json!({"name":"Network"}), json!({"name":"Uptime"})]
}

impl Plugin for Dashboard {
    fn init(&mut self) {
        timer::set(1, 250);
        self.show();
    }
    fn on_open(&mut self, _: &str, _: Context) {
        self.show();
    }
    fn on_event(&mut self, _: &str, name: &str, args: Value) {
        match name {
            "sharing" => {
                self.sharing = args["value"].as_bool().unwrap_or(!self.sharing);
                if !self.sharing {
                    self.control = false;
                    self.viewers.clear();
                }
            }
            "control" => {
                self.control = args["value"].as_bool().unwrap_or(!self.control);
            }
            "shown" => {
                self.shown = self.shown.saturating_add(1);
                if self.live() {
                    self.sample();
                }
            }
            "hidden" => self.shown = self.shown.saturating_sub(1),
            "select" => {
                let device = args["device"].as_str().or(args["value"].as_str()).unwrap_or("").to_string();
                self.choose(&device);
            }
            "local" => self.choose(&ournet_plugin::this_device()),
            "refresh" => self.sample(),
            "pause" | "watch" => {
                self.paused = !self.paused;
                if !self.paused {
                    self.sample();
                }
            }
            "interval" => {
                self.interval = match args["value"].as_str() {
                    Some("2000") => 2000,
                    Some("5000") => 5000,
                    _ => 1000,
                };
            }
            "tab" => {
                self.tab = args["value"].as_str().unwrap_or("performance").into();
                if self.tab == "processes" && self.processes.is_empty() && !self.client.target.is_empty() {
                    self.sample();
                }
            }
            "focus" => self.focus = args["key"].as_str().unwrap_or("cpu").into(),
            "pick" => {
                let pid = args["id"].as_u64();
                self.selected = self.processes.iter().find(|p| Some(p.pid) == pid).cloned();
                self.confirming = false;
            }
            "stop" => {
                // Asks first: from the End-task button, or a row's PID.
                if let Some(pid) = args["pid"].as_u64() {
                    self.selected = self.processes.iter().find(|p| p.pid == pid).cloned();
                }
                self.confirming = self.selected.is_some();
            }
            "cancel" => self.confirming = false,
            "confirm" => {
                if let Some(p) = self.selected.take().filter(|_| self.confirming) {
                    self.confirming = false;
                    self.notice = format!("Ending {}…", p.name);
                    if self.client.pending.is_some() {
                        self.stop_after = Some(p);
                    } else {
                        self.end(p);
                    }
                }
            }
            "dismiss" => self.notice.clear(),
            _ => {}
        }
        self.show();
    }
    fn on_request(&mut self, from: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
        if !common::own(from) {
            return Err("Only your own devices may access this dashboard".into());
        }
        if payload.len() > 1024 {
            return Err("Request too large".into());
        }
        let v: Value = serde_json::from_slice(payload).map_err(|_| "Invalid request")?;
        let local = from == ournet_plugin::this_device();
        if !local && self.sharing {
            let first = !self.viewers.contains_key(from);
            self.viewers.insert(from.to_string(), ournet_plugin::now());
            if first {
                self.show();
            }
        }
        let mut result = match v["op"].as_str() {
            Some("snapshot") if self.sharing || local => device::snapshot(v["processes"] == true)?,
            Some("stop") if self.control && (self.sharing || local) => {
                let pid = v["pid"]
                    .as_u64()
                    .and_then(|p| u32::try_from(p).ok())
                    .ok_or("Invalid process")?;
                device::stop(pid, v["started"].as_u64().ok_or("Missing process start")?)?;
                device::snapshot(true)?
            }
            Some("stop") => return Err("Allow ending processes on the receiving device first".into()),
            _ => {
                return Err("Enable sharing on the receiving device first".into())
            }
        };
        if let Some(rows) = result["processes"].as_array_mut() {
            if v["v"].as_u64().unwrap_or(1) >= 2 {
                // Rows as arrays: a third of the size, every few seconds.
                let compact: Vec<_> = rows.iter().take(ROWS).map(|p| json!([p["pid"], p["started"], p["name"],
                    p["cpu"], p["memory"], p["diskRead"], p["diskWrite"]])).collect();
                result["processRows"] = json!(compact);
                result.as_object_mut().map(|o| o.remove("processes"));
            } else {
                rows.truncate(LEGACY_ROWS);
            }
        }
        result["sharing"] = json!(self.sharing);
        result["control"] = json!(self.control);
        Ok(result.to_string().into_bytes())
    }
    fn on_reply(&mut self, id: u64, reply: Result<Vec<u8>, String>) {
        let stopping = self.stop_request == Some(id);
        if stopping {
            self.stop_request = None;
        }
        let failed = reply.is_err();
        if let Some(v) = self.client.reply(id, reply) {
            self.accept(v);
            if self.client.link == common::Link::Ok {
                self.client.status = if self.paused { "Paused" } else { "Connected" }.into();
            }
        }
        if stopping {
            self.notice = if failed {
                self.client.status.clone()
            } else {
                self.notice.replacen("Ending ", "Ended ", 1).trim_end_matches('…').to_string()
            };
        }
        if failed {
            self.next_at = ournet_plugin::now() + BACKOFF;
        }
        if let Some(p) = self.stop_after.take() {
            self.end(p);
        }
        self.show();
    }
    fn on_timer(&mut self, _: u64) {
        let now = ournet_plugin::now();
        let mut changed = false;
        let had_pending = self.client.pending.is_some();
        self.client.tick();
        if had_pending && self.client.pending.is_none() {
            self.next_at = now + BACKOFF;
            if self.stop_request.take().is_some() {
                self.notice = "The device did not answer; the process may not have ended".into();
            }
            changed = true;
        }
        let before = self.viewers.len();
        self.viewers.retain(|_, at| now.saturating_sub(*at) < VIEWER_IDLE);
        changed |= before != self.viewers.len();
        if self.live() && self.client.pending.is_none() && now >= self.next_at {
            self.sample();
            if self.local() {
                changed = true;
            }
        }
        if changed {
            self.show();
        }
        timer::set(1, 250);
    }
}
ournet_plugin::plugin!(Dashboard);
