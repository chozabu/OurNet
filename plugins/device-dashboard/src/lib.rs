use ournet_plugin::{device, json, timer, ui, Context, Plugin, Value};
#[path = "../../device-common.rs"]
mod common;
const SURFACE: &str = "Dashboard";
#[derive(Default)]
struct Dashboard {
    client: common::Client,
    sharing: bool,
    control: bool,
    watching: bool,
    until: u64,
    report: Value,
    history: Vec<f64>,
    confirm: Value,
}
impl Dashboard {
    fn show(&self) {
        self.client.show(SURFACE);
        let v = &self.report;
        let number = |k: &str| v[k].as_f64().unwrap_or(0.0);
        let mut metrics = Vec::new();
        if !v.is_null() {
            metrics.extend([
                json!({"name":"CPU", "value":v["cpu"].as_f64().map(|n|format!("{n:.1}%")).unwrap_or("Sampling…".into())}),
                json!({"name":"Memory", "value":format!("{} / {}",common::bytes(number("memoryUsed")),common::bytes(number("memoryTotal")))}),
                json!({"name":"Network", "value":if v["receivedPerSecond"].is_null(){"Sampling…".into()}else{format!("↓ {}/s · ↑ {}/s",common::bytes(number("receivedPerSecond")),common::bytes(number("sentPerSecond")))}}),
                json!({"name":"Uptime", "value":format!("{} h {} min",number("uptime") as u64/3600,number("uptime") as u64/60%60)}),
            ]);
            if let Some(ts) = v["temperatures"].as_array() {
                for t in ts {
                    metrics.push(json!({"name":t["name"],"value":format!("{:.1} °C",t["celsius"].as_f64().unwrap_or(0.0))}));
                }
            }
        }
        let processes:Vec<_> = v["processes"].as_array().into_iter().flatten().map(|p|json!({
            "pid":p["pid"],"started":p["started"],"name":p["name"],
            "detail":format!("PID {} · {:.1}% CPU · {}",p["pid"],p["cpu"].as_f64().unwrap_or(0.0),common::bytes(p["memory"].as_f64().unwrap_or(0.0)))
        })).collect();
        let graph:Vec<_> = self.history.iter().enumerate().map(|(i,n)|json!({"op":"rect","x":i as f64*5.0,"y":100.0-n,"w":4.0,"h":n.max(0.1),"color":0xff55bb99u32})).collect();
        ui::update(
            SURFACE,
            &json!({"sharing":self.sharing,"control":self.control,"watching":self.watching,
            "shareLabel":if self.sharing {"Stop sharing this device"}else{"Share this device's metrics"},
            "controlLabel":if self.control {"Disable process control"}else{"Allow ending processes"},
            "watchLabel":if self.watching {"Pause updates"}else{"Watch for 5 minutes"},
            "metrics":metrics,"processes":processes,"graph":graph,"hasReport":!v.is_null(),
            "confirming":!self.confirm.is_null(),"confirmName":self.confirm["name"].as_str().unwrap_or(""),
            "sensorNote":"GPU load and fan speed are unavailable. Temperatures appear only when exposed by the system.",
            "historyLabel":"CPU · last 60 samples · 0–100%"}),
        );
    }
    fn sample(&mut self) {
        self.dispatch(json!({"op":"snapshot","processes":true}));
    }
    fn dispatch(&mut self, v: Value) {
        if self.client.target == ournet_plugin::this_device() {
            self.client.status = if v["op"] == "stop" {
                "Ending process…"
            } else {
                "Reading system metrics…"
            }
            .into();
            self.client.show(SURFACE);
            match self.on_request(&ournet_plugin::this_device(), v.to_string().as_bytes()) {
                Ok(bytes) => {
                    if let Ok(v) = serde_json::from_slice(&bytes) {
                        self.accept(v);
                        self.client.status = "This device · updated just now".into();
                    }
                }
                Err(e) => self.client.status = e,
            }
        } else {
            self.client.send(&v);
        }
    }
    fn accept(&mut self, v: Value) {
        if let Some(n) = v["cpu"].as_f64() {
            self.history.push(n.clamp(0.0, 100.0));
            if self.history.len() > 60 {
                self.history.remove(0);
            }
        }
        self.report = v;
    }
}
impl Plugin for Dashboard {
    fn init(&mut self) {
        timer::set(1, 1000);
        self.show();
    }
    fn on_open(&mut self, _: &str, _: Context) {
        self.show();
    }
    fn on_event(&mut self, _: &str, name: &str, args: Value) {
        match name {
            "sharing" => {
                self.sharing = !self.sharing;
                if !self.sharing {
                    self.control = false;
                }
            }
            "control" => {
                if self.sharing {
                    self.control = !self.control;
                }
            }
            "select" => {
                self.client.select(args["device"].as_str().unwrap_or(""));
                self.report = Value::Null;
                self.history.clear();
                self.confirm = Value::Null;
                self.watching = false;
                self.sample();
            }
            "local" => {
                self.client.select(&ournet_plugin::this_device());
                self.history.clear();
                self.confirm = Value::Null;
                self.report = Value::Null;
                self.sample();
            }
            "refresh" => self.sample(),
            "watch" => {
                self.watching = !self.watching;
                self.until = ournet_plugin::now() + 300_000;
                if self.watching {
                    self.sample();
                }
            }
            "stop" => {
                if let Some(p) = self.report["processes"]
                    .as_array()
                    .and_then(|ps| ps.iter().find(|p| p["pid"] == args["pid"]))
                {
                    self.confirm = p.clone();
                }
            }
            "cancel" => self.confirm = Value::Null,
            "confirm" => {
                if !self.confirm.is_null() && self.client.pending.is_none() {
                    self.dispatch(json!({"op":"stop","pid":self.confirm["pid"],"started":self.confirm["started"]}));
                    self.confirm = Value::Null;
                }
            }
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
        let result = match v["op"].as_str() {
            Some("snapshot") if self.sharing || local => device::snapshot(v["processes"] == true)?,
            Some("stop") if self.control && self.sharing => {
                let pid = v["pid"]
                    .as_u64()
                    .and_then(|p| u32::try_from(p).ok())
                    .ok_or("Invalid process")?;
                device::stop(pid, v["started"].as_u64().ok_or("Missing process start")?)?;
                device::snapshot(true)?
            }
            _ => {
                return Err("Enable sharing / process control on the receiving device first".into())
            }
        };
        Ok(result.to_string().into_bytes())
    }
    fn on_reply(&mut self, id: u64, reply: Result<Vec<u8>, String>) {
        if let Some(v) = self.client.reply(id, reply) {
            self.accept(v);
        }
        self.show();
    }
    fn on_timer(&mut self, _: u64) {
        let had_pending = self.client.pending.is_some();
        self.client.tick();
        if had_pending && self.client.pending.is_none() {
            self.show();
        }
        if self.watching {
            if ournet_plugin::now() > self.until {
                self.watching = false;
                self.client.status = "Automatic updates paused after 5 minutes".into();
            } else if self.confirm.is_null() {
                self.sample();
            }
            self.show();
        }
        timer::set(1, 2000);
    }
}
ournet_plugin::plugin!(Dashboard);
