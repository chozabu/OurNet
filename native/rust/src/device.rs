//! Permissioned device capabilities. Called on a plugin thread, never a frame.
use serde_json::{json, Value};

#[cfg(windows)]
#[derive(Default)]
pub struct Monitor {
    system: sysinfo::System,
    networks: sysinfo::Networks,
    sampled: Option<std::time::Instant>,
    processes_at: Option<std::time::Instant>,
    sample: Value,
    rows: Value,
    shown: std::collections::HashMap<u32, u64>,
}

#[cfg(not(windows))]
#[derive(Default)]
pub struct Monitor;

#[cfg(windows)]
impl Monitor {
    pub fn snapshot(&mut self, processes: bool) -> Result<Value, String> {
        use std::time::{Duration, Instant};
        let now = Instant::now();
        if self
            .sampled
            .is_none_or(|at| now.duration_since(at) >= Duration::from_secs(1))
        {
            let elapsed = self.sampled.map(|at| now.duration_since(at).as_secs_f64());
            self.system.refresh_cpu_usage();
            self.system.refresh_memory();
            self.networks.refresh(true);
            let received: u64 = self.networks.values().map(|n| n.received()).sum();
            let sent: u64 = self.networks.values().map(|n| n.transmitted()).sum();
            let temperatures = temperatures();
            self.sample = json!({
                "platform":"windows", "host":sysinfo::System::host_name(),
                "cpu": elapsed.map(|_| self.system.global_cpu_usage()),
                "memoryUsed":self.system.used_memory(), "memoryTotal":self.system.total_memory(),
                "receivedPerSecond":elapsed.map(|s| received as f64 / s),
                "sentPerSecond":elapsed.map(|s| sent as f64 / s),
                "uptime":sysinfo::System::uptime(), "temperatures":temperatures,
                "gpu":null, "fan":null,
            });
            self.sampled = Some(Instant::now());
        }
        if processes
            && self
                .processes_at
                .is_none_or(|at| now.duration_since(at) >= Duration::from_secs(3))
        {
            self.system.refresh_processes_specifics(
                sysinfo::ProcessesToUpdate::All,
                true,
                sysinfo::ProcessRefreshKind::nothing()
                    .with_cpu()
                    .with_memory(),
            );
            let mut rows: Vec<_> = self.system.processes().values().collect();
            rows.sort_by(|a, b| {
                b.cpu_usage()
                    .total_cmp(&a.cpu_usage())
                    .then(b.memory().cmp(&a.memory()))
            });
            self.shown.clear();
            let rows: Vec<_> = rows
                .into_iter()
                .take(128)
                .map(|p| {
                    self.shown.insert(p.pid().as_u32(), p.start_time());
                    json!({"pid":p.pid().as_u32(), "started":p.start_time(),
                    "name":p.name().to_string_lossy(), "cpu":p.cpu_usage(), "memory":p.memory()})
                })
                .collect();
            self.rows = json!(rows);
            self.processes_at = Some(Instant::now());
        }
        let mut result = self.sample.clone();
        if processes {
            result["processes"] = self.rows.clone();
        }
        Ok(result)
    }

    pub fn stop(&mut self, pid: u32, started: u64) -> Result<(), String> {
        if pid <= 4 || pid == std::process::id() || self.shown.get(&pid) != Some(&started) {
            return Err("Select a current, non-system process from the dashboard".into());
        }
        self.system.refresh_processes_specifics(
            sysinfo::ProcessesToUpdate::Some(&[sysinfo::Pid::from_u32(pid)]),
            true,
            sysinfo::ProcessRefreshKind::nothing(),
        );
        let process = self
            .system
            .process(sysinfo::Pid::from_u32(pid))
            .ok_or("Process already exited")?;
        if process.start_time() != started {
            return Err("Process changed; refresh first".into());
        }
        if !process.kill() {
            return Err("The system refused to end this process".into());
        }
        self.shown.remove(&pid);
        self.processes_at = None;
        Ok(())
    }
}

/// WMI providers can wait indefinitely. At most one sensor worker exists for
/// the process and one refresh may wait behind it; resource requests only
/// clone its bounded cache. No worker is created until monitoring is used.
#[cfg(windows)]
fn temperatures() -> Vec<Value> {
    use std::sync::{mpsc, Arc, Mutex, OnceLock};
    use std::time::{Duration, Instant};
    struct Sensors {
        request: mpsc::SyncSender<()>,
        values: Arc<Mutex<Vec<Value>>>,
    }
    static SENSORS: OnceLock<Sensors> = OnceLock::new();
    let sensors = SENSORS.get_or_init(|| {
        let (request, receive) = mpsc::sync_channel(1);
        let values = Arc::new(Mutex::new(Vec::new()));
        let output = values.clone();
        let _ = std::thread::Builder::new()
            .name("ournet-sensors".into())
            .spawn(move || {
                let mut components = sysinfo::Components::new();
                let mut next = Instant::now();
                while receive.recv().is_ok() {
                    if Instant::now() < next {
                        continue;
                    }
                    components.refresh(true);
                    let sample: Vec<_> = components
                        .iter()
                        .filter_map(|c| {
                            c.temperature()
                                .map(|t| json!({"name":c.label(),"celsius":t}))
                        })
                        .take(32)
                        .collect();
                    next = Instant::now()
                        + Duration::from_secs(if sample.is_empty() { 30 } else { 2 });
                    if let Ok(mut cache) = output.lock() {
                        *cache = sample;
                    }
                }
            });
        Sensors { request, values }
    });
    let _ = sensors.request.try_send(());
    sensors.values.lock().map(|v| v.clone()).unwrap_or_default()
}

#[cfg(not(windows))]
impl Monitor {
    pub fn snapshot(&mut self, _: bool) -> Result<Value, String> {
        Err("System monitoring is currently supported on Windows receivers".into())
    }
    pub fn stop(&mut self, _: u32, _: u64) -> Result<(), String> {
        Err("Process control is currently supported on Windows receivers".into())
    }
}

pub fn input(command: &str) -> Result<(), String> {
    if command.len() > 20_000 {
        return Err("Input command too large".into());
    }
    let command: Value = serde_json::from_str(command).map_err(|_| "Invalid input command")?;
    #[cfg(windows)]
    {
        windows_input(&command)
    }
    #[cfg(not(windows))]
    {
        let _ = command;
        Err("Mouse and keyboard control currently needs a Windows receiver".into())
    }
}

#[cfg(windows)]
fn windows_input(v: &Value) -> Result<(), String> {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::*;
    let mut events = Vec::new();
    let key = |vk: u16, scan: u16, flags: u32| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: scan,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    let mouse = |dx, dy, data, flags| INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx,
                dy,
                mouseData: data,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    match v["op"].as_str().unwrap_or("") {
        "move" => {
            let x = v["dx"].as_i64().ok_or("Missing dx")?;
            let y = v["dy"].as_i64().ok_or("Missing dy")?;
            if !(-2000..=2000).contains(&x) || !(-2000..=2000).contains(&y) {
                return Err("Movement out of range".into());
            }
            events.push(mouse(x as i32, y as i32, 0, MOUSEEVENTF_MOVE));
        }
        "click" => {
            let (down, up) = match v["button"].as_str() {
                Some("left") => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
                Some("right") => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
                _ => return Err("Unknown mouse button".into()),
            };
            events.push(mouse(0, 0, 0, down));
            events.push(mouse(0, 0, 0, up));
        }
        "scroll" => {
            let n = v["amount"]
                .as_i64()
                .filter(|n| (-10..=10).contains(n))
                .ok_or("Scroll out of range")?;
            events.push(mouse(0, 0, (n as i32 * 120) as u32, MOUSEEVENTF_WHEEL));
        }
        "type" => {
            let text = v["text"].as_str().ok_or("Missing text")?;
            if text.len() > 16384 {
                return Err("Text exceeds 16 KiB".into());
            }
            for unit in text.encode_utf16() {
                events.push(key(0, unit, KEYEVENTF_UNICODE));
                events.push(key(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
            }
        }
        "paste" => {
            events.extend([
                key(VK_CONTROL, 0, 0),
                key(b'V' as u16, 0, 0),
                key(b'V' as u16, 0, KEYEVENTF_KEYUP),
                key(VK_CONTROL, 0, KEYEVENTF_KEYUP),
            ]);
        }
        "key" => {
            let vk = match v["key"].as_str().unwrap_or("") {
                "enter" => VK_RETURN,
                "backspace" => VK_BACK,
                "tab" => VK_TAB,
                "escape" => VK_ESCAPE,
                "left" => VK_LEFT,
                "right" => VK_RIGHT,
                "up" => VK_UP,
                "down" => VK_DOWN,
                "pageup" => VK_PRIOR,
                "pagedown" => VK_NEXT,
                "play" => VK_MEDIA_PLAY_PAUSE,
                "next" => VK_MEDIA_NEXT_TRACK,
                "previous" => VK_MEDIA_PREV_TRACK,
                "volumeup" => VK_VOLUME_UP,
                "volumedown" => VK_VOLUME_DOWN,
                "mute" => VK_VOLUME_MUTE,
                _ => return Err("Unknown key".into()),
            };
            events.extend([key(vk, 0, 0), key(vk, 0, KEYEVENTF_KEYUP)]);
        }
        _ => return Err("Unknown input operation".into()),
    }
    if events.is_empty() {
        return Ok(());
    }
    let sent = unsafe {
        SendInput(
            events.len() as u32,
            events.as_ptr(),
            std::mem::size_of::<INPUT>() as i32,
        )
    };
    if sent != events.len() as u32 {
        return Err("Windows refused input (the target may be elevated or locked)".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn rejects_unknown_and_oversized_input_without_touching_the_os() {
        assert!(super::input("{\"op\":\"shell\"}").is_err());
        assert!(super::input(&"x".repeat(20_001)).is_err());
        assert!(super::input("not json").is_err());
        assert!(super::input("{\"op\":\"move\",\"dx\":-9223372036854775808,\"dy\":0}").is_err());
    }
    #[cfg(windows)]
    #[test]
    fn sampler_bounds_processes_caches_samples_and_refuses_self() {
        let mut monitor = super::Monitor::default();
        let a = monitor.snapshot(true).unwrap();
        assert!(a["memoryTotal"].as_u64().unwrap() > 0);
        assert!(a["processes"].as_array().unwrap().len() <= 128);
        // Test the cache, independently of how long Windows took to obtain
        // its first process/sensor sample under load.
        monitor.sampled = Some(std::time::Instant::now());
        monitor.processes_at = Some(std::time::Instant::now());
        let b = monitor.snapshot(true).unwrap();
        assert_eq!(a, b);
        assert!(monitor.stop(std::process::id(), 0).is_err());
        assert!(monitor.stop(0, 0).is_err());
    }
}
