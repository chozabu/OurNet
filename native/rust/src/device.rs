//! Permissioned device capabilities. Called on a plugin thread, never a frame.
use serde_json::{json, Value};

/// Processes one sample lists at most, by CPU then memory.
pub const PROCESS_LIMIT: usize = 512;

/// Logical CPUs reported per core at most.
#[cfg(windows)]
const CORE_LIMIT: usize = 256;

#[cfg(windows)]
#[derive(Default)]
pub struct Monitor {
    system: sysinfo::System,
    networks: sysinfo::Networks,
    sampled: Option<std::time::Instant>,
    processes_at: Option<std::time::Instant>,
    sample: Value,
    rows: Value,
    /// PID → (start time, name) of every process the last sample listed:
    /// only those may be ended.
    shown: std::collections::HashMap<u32, (u64, String)>,
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
            if self.sampled.is_none() {
                self.system.refresh_cpu_frequency();
            }
            self.networks.refresh(true);
            let received: u64 = self.networks.values().map(|n| n.received()).sum();
            let sent: u64 = self.networks.values().map(|n| n.transmitted()).sum();
            let slow = slow_sensors();
            let cpus = self.system.cpus();
            let counts = performance_counts();
            self.sample = json!({
                "platform":"windows", "host":sysinfo::System::host_name(),
                "os":sysinfo::System::long_os_version(),
                "cpu": elapsed.map(|_| self.system.global_cpu_usage()),
                "perCore": elapsed.map(|_| cpus.iter().take(CORE_LIMIT).map(|c| c.cpu_usage()).collect::<Vec<_>>()),
                "cpuBrand": cpus.first().map(|c| c.brand().trim().to_string()),
                "cpuFrequency": cpus.first().map(|c| c.frequency()),
                "cores": cpus.len(), "physicalCores": sysinfo::System::physical_core_count(),
                "memoryUsed":self.system.used_memory(), "memoryTotal":self.system.total_memory(),
                "memoryAvailable":self.system.available_memory(),
                "swapUsed":self.system.used_swap(), "swapTotal":self.system.total_swap(),
                "receivedPerSecond":elapsed.map(|s| received as f64 / s),
                "sentPerSecond":elapsed.map(|s| sent as f64 / s),
                "uptime":sysinfo::System::uptime(), "temperatures":slow.temperatures,
                "disks":slow.disks, "diskReadPerSecond":slow.read, "diskWritePerSecond":slow.write,
                "processCount":counts.map(|c| c.0), "threadCount":counts.map(|c| c.1),
                "handleCount":counts.map(|c| c.2), "commitUsed":counts.map(|c| c.3),
                "commitLimit":counts.map(|c| c.4),
                "gpu":(!slow.gpus.is_empty()).then_some(&slow.gpus), "fan":null,
            });
            self.sampled = Some(Instant::now());
        }
        if processes
            && self
                .processes_at
                .is_none_or(|at| now.duration_since(at) >= Duration::from_secs(2))
        {
            let elapsed = self
                .processes_at
                .map(|at| now.duration_since(at).as_secs_f64().max(0.001));
            self.system.refresh_processes_specifics(
                sysinfo::ProcessesToUpdate::All,
                true,
                sysinfo::ProcessRefreshKind::nothing()
                    .with_cpu()
                    .with_memory()
                    .with_disk_usage(),
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
                .take(PROCESS_LIMIT)
                .map(|p| {
                    let name = p.name().to_string_lossy().into_owned();
                    self.shown
                        .insert(p.pid().as_u32(), (p.start_time(), name.clone()));
                    let disk = p.disk_usage();
                    json!({"pid":p.pid().as_u32(), "started":p.start_time(),
                    "name":name, "cpu":p.cpu_usage(), "memory":p.memory(),
                    "diskRead":elapsed.map(|s| disk.read_bytes as f64 / s),
                    "diskWrite":elapsed.map(|s| disk.written_bytes as f64 / s)})
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

    /// Ends [pid] if it is the process the last sample showed. Returns its
    /// name, for the receiving device's session log.
    pub fn stop(&mut self, pid: u32, started: u64) -> Result<String, String> {
        let name = match self.shown.get(&pid) {
            Some((at, name)) if *at == started && pid > 4 && pid != std::process::id() => {
                name.clone()
            }
            _ => return Err("Select a current, non-system process from the dashboard".into()),
        };
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
        Ok(name)
    }
}

/// System-wide process, thread and handle counts and commit charge in
/// bytes, from one `GetPerformanceInfo` call.
#[cfg(windows)]
fn performance_counts() -> Option<(u32, u32, u32, u64, u64)> {
    use windows_sys::Win32::System::ProcessStatus::{GetPerformanceInfo, PERFORMANCE_INFORMATION};
    let mut info: PERFORMANCE_INFORMATION = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<PERFORMANCE_INFORMATION>() as u32;
    info.cb = size;
    if unsafe { GetPerformanceInfo(&mut info, size) } == 0 {
        return None;
    }
    let page = info.PageSize as u64;
    Some((
        info.ProcessCount,
        info.ThreadCount,
        info.HandleCount,
        info.CommitTotal as u64 * page,
        info.CommitLimit as u64 * page,
    ))
}

/// The ACPI thermal zones Windows publishes as performance counters: read
/// without administrator rights, unlike the WMI class sysinfo uses.
#[cfg(windows)]
struct ThermalZones {
    query: windows_sys::Win32::System::Performance::PDH_HQUERY,
    counter: windows_sys::Win32::System::Performance::PDH_HCOUNTER,
}

#[cfg(windows)]
impl ThermalZones {
    fn open() -> Option<ThermalZones> {
        use windows_sys::Win32::System::Performance::*;
        let path: Vec<u16> = "\\Thermal Zone Information(*)\\High Precision Temperature\0"
            .encode_utf16()
            .collect();
        let mut query = std::ptr::null_mut();
        let mut counter = std::ptr::null_mut();
        unsafe {
            if PdhOpenQueryW(std::ptr::null(), 0, &mut query) != 0 {
                return None;
            }
            if PdhAddEnglishCounterW(query, path.as_ptr(), 0, &mut counter) != 0 {
                PdhCloseQuery(query);
                return None;
            }
        }
        Some(ThermalZones { query, counter })
    }

    /// Each zone's temperature, from tenths of a kelvin.
    fn read(&self) -> Vec<Value> {
        use windows_sys::Win32::System::Performance::*;
        unsafe {
            if PdhCollectQueryData(self.query) != 0 {
                return Vec::new();
            }
            let (mut size, mut count) = (0u32, 0u32);
            let status = PdhGetFormattedCounterArrayW(
                self.counter,
                PDH_FMT_DOUBLE,
                &mut size,
                &mut count,
                std::ptr::null_mut(),
            );
            if status != PDH_MORE_DATA || size == 0 || size > 1 << 20 {
                return Vec::new();
            }
            // u64 words keep the items' doubles aligned.
            let mut buffer = vec![0u64; (size as usize).div_ceil(8)];
            let items = buffer.as_mut_ptr() as *mut PDH_FMT_COUNTERVALUE_ITEM_W;
            if PdhGetFormattedCounterArrayW(self.counter, PDH_FMT_DOUBLE, &mut size, &mut count, items) != 0 {
                return Vec::new();
            }
            (0..count.min(32) as usize)
                .filter_map(|i| {
                    let item = &*items.add(i);
                    if item.FmtValue.CStatus != 0 {
                        return None;
                    }
                    let celsius = item.FmtValue.Anonymous.doubleValue / 10.0 - 273.15;
                    if !(-20.0..=150.0).contains(&celsius) {
                        return None;
                    }
                    let mut len = 0;
                    while *item.szName.add(len) != 0 && len < 256 {
                        len += 1;
                    }
                    let name = String::from_utf16_lossy(std::slice::from_raw_parts(item.szName, len));
                    let name = name.trim_start_matches("\\_tz.").trim_start_matches("\\_TZ.");
                    Some(json!({"name":format!("Thermal zone {name}"),"celsius":(celsius * 10.0).round() / 10.0}))
                })
                .collect()
        }
    }
}

#[cfg(windows)]
impl Drop for ThermalZones {
    fn drop(&mut self) {
        unsafe { windows_sys::Win32::System::Performance::PdhCloseQuery(self.query) };
    }
}

/// NVIDIA GPUs through the driver's NVML library, when it is installed:
/// load, memory and temperature, without administrator rights. Loaded from
/// the system directory or the driver's own, never the working directory.
#[cfg(windows)]
struct Nvml {
    count: unsafe extern "C" fn(*mut u32) -> i32,
    handle: unsafe extern "C" fn(u32, *mut *mut std::ffi::c_void) -> i32,
    name: unsafe extern "C" fn(*mut std::ffi::c_void, *mut u8, u32) -> i32,
    temperature: unsafe extern "C" fn(*mut std::ffi::c_void, i32, *mut u32) -> i32,
    utilization: unsafe extern "C" fn(*mut std::ffi::c_void, *mut [u32; 2]) -> i32,
    memory: unsafe extern "C" fn(*mut std::ffi::c_void, *mut [u64; 3]) -> i32,
}

#[cfg(windows)]
impl Nvml {
    fn open() -> Option<Nvml> {
        use windows_sys::Win32::System::LibraryLoader::*;
        let wide = |s: &str| s.encode_utf16().chain([0]).collect::<Vec<u16>>();
        unsafe {
            let mut module = LoadLibraryExW(wide("nvml.dll").as_ptr(), std::ptr::null_mut(), LOAD_LIBRARY_SEARCH_SYSTEM32);
            if module.is_null() {
                let program_files = std::env::var("ProgramW6432").unwrap_or("C:\\Program Files".into());
                let path = format!("{program_files}\\NVIDIA Corporation\\NVSMI\\nvml.dll");
                module = LoadLibraryExW(wide(&path).as_ptr(), std::ptr::null_mut(), 0);
            }
            if module.is_null() {
                return None;
            }
            macro_rules! function {
                ($name:literal) => {
                    std::mem::transmute(GetProcAddress(module, concat!($name, "\0").as_ptr())?)
                };
            }
            let init: unsafe extern "C" fn() -> i32 = function!("nvmlInit_v2");
            if init() != 0 {
                return None;
            }
            Some(Nvml {
                count: function!("nvmlDeviceGetCount_v2"),
                handle: function!("nvmlDeviceGetHandleByIndex_v2"),
                name: function!("nvmlDeviceGetName"),
                temperature: function!("nvmlDeviceGetTemperature"),
                utilization: function!("nvmlDeviceGetUtilizationRates"),
                memory: function!("nvmlDeviceGetMemoryInfo"),
            })
        }
    }

    fn read(&self) -> Vec<Value> {
        let mut count = 0;
        if unsafe { (self.count)(&mut count) } != 0 {
            return Vec::new();
        }
        (0..count.min(8))
            .filter_map(|i| unsafe {
                let mut device = std::ptr::null_mut();
                if (self.handle)(i, &mut device) != 0 {
                    return None;
                }
                let mut name = [0u8; 96];
                (self.name)(device, name.as_mut_ptr(), name.len() as u32);
                let end = name.iter().position(|b| *b == 0).unwrap_or(name.len());
                let mut celsius = 0;
                let mut load = [0u32; 2];
                let mut memory = [0u64; 3];
                Some(json!({
                    "name": String::from_utf8_lossy(&name[..end]),
                    "celsius": ((self.temperature)(device, 0, &mut celsius) == 0).then_some(celsius),
                    "load": ((self.utilization)(device, &mut load) == 0).then_some(load[0]),
                    "memoryTotal": ((self.memory)(device, &mut memory) == 0).then_some(memory[0]),
                    "memoryUsed": (memory[0] > 0).then_some(memory[2]),
                }))
            })
            .collect()
    }
}

/// What the sensor worker last read.
#[cfg(windows)]
#[derive(Clone, Default)]
struct Slow {
    temperatures: Vec<Value>,
    gpus: Vec<Value>,
    disks: Vec<Value>,
    read: Option<f64>,
    write: Option<f64>,
}

/// WMI providers can wait indefinitely, and a disk may be slow to answer.
/// At most one sensor worker exists for the process and one refresh may
/// wait behind it; resource requests only clone its bounded cache. No worker
/// is created until monitoring is used.
#[cfg(windows)]
fn slow_sensors() -> Slow {
    use std::sync::{mpsc, Arc, Mutex, OnceLock};
    use std::time::{Duration, Instant};
    struct Sensors {
        request: mpsc::SyncSender<()>,
        values: Arc<Mutex<Slow>>,
    }
    static SENSORS: OnceLock<Sensors> = OnceLock::new();
    let sensors = SENSORS.get_or_init(|| {
        let (request, receive) = mpsc::sync_channel(1);
        let values = Arc::new(Mutex::new(Slow::default()));
        let output = values.clone();
        let _ = std::thread::Builder::new()
            .name("ournet-sensors".into())
            .spawn(move || {
                use sysinfo::DiskRefreshKind;
                let mut components = sysinfo::Components::new();
                let zones = ThermalZones::open();
                let nvml = Nvml::open();
                let mut wmi: Vec<Value> = Vec::new();
                let mut disks = sysinfo::Disks::new();
                let (mut next_components, mut next_list) = (Instant::now(), Instant::now());
                let mut disks_at: Option<Instant> = None;
                while receive.recv().is_ok() {
                    let now = Instant::now();
                    let mut slow = output.lock().map(|v| v.clone()).unwrap_or_default();
                    if now >= next_components {
                        // WMI's sensors usually need administrator rights:
                        // retried rarely while they give nothing.
                        components.refresh(true);
                        wmi = components
                            .iter()
                            .filter_map(|c| {
                                c.temperature()
                                    .map(|t| json!({"name":c.label(),"celsius":t}))
                            })
                            .take(32)
                            .collect();
                        next_components = Instant::now()
                            + Duration::from_secs(if wmi.is_empty() { 30 } else { 2 });
                    }
                    slow.gpus = nvml.as_ref().map(Nvml::read).unwrap_or_default();
                    slow.temperatures = wmi.clone();
                    slow.temperatures.extend(zones.as_ref().map(ThermalZones::read).unwrap_or_default());
                    slow.temperatures.extend(slow.gpus.iter().filter(|g| g["celsius"].is_number())
                        .map(|g| json!({"name":g["name"],"celsius":g["celsius"]})));
                    slow.temperatures.truncate(48);
                    if disks_at.is_none_or(|at| now.duration_since(at) >= Duration::from_secs(1)) {
                        // Volumes come and go: the list is read rarely, each
                        // listed disk's counters every sample.
                        let listed = now >= next_list;
                        if listed {
                            disks.refresh_specifics(true, DiskRefreshKind::everything());
                            next_list = now + Duration::from_secs(30);
                        } else {
                            for d in disks.list_mut() {
                                d.refresh_specifics(DiskRefreshKind::nothing().with_io_usage());
                            }
                        }
                        let elapsed = disks_at
                            .filter(|_| !listed)
                            .map(|at| now.duration_since(at).as_secs_f64().max(0.001));
                        let (mut read, mut write) = (0.0, 0.0);
                        slow.disks = disks
                            .list()
                            .iter()
                            .take(16)
                            .map(|d| {
                                let usage = d.usage();
                                let r = elapsed.map(|s| usage.read_bytes as f64 / s);
                                let w = elapsed.map(|s| usage.written_bytes as f64 / s);
                                read += r.unwrap_or(0.0);
                                write += w.unwrap_or(0.0);
                                json!({"name":d.name().to_string_lossy(),
                                    "mount":d.mount_point().to_string_lossy(),
                                    "kind":format!("{}", d.kind()),
                                    "total":d.total_space(), "available":d.available_space(),
                                    "removable":d.is_removable(),
                                    "readPerSecond":r, "writePerSecond":w})
                            })
                            .collect();
                        // A fresh list restarts the counters: keep the last rate.
                        if elapsed.is_some() {
                            slow.read = Some(read);
                            slow.write = Some(write);
                        }
                        disks_at = Some(now);
                    }
                    if let Ok(mut cache) = output.lock() {
                        *cache = slow;
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
    pub fn stop(&mut self, _: u32, _: u64) -> Result<String, String> {
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
                "space" => VK_SPACE,
                "delete" => VK_DELETE,
                "home" => VK_HOME,
                "end" => VK_END,
                "f5" => VK_F5,
                "f11" => VK_F11,
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
        assert!(a["processes"].as_array().unwrap().len() <= super::PROCESS_LIMIT);
        assert!(a["cores"].as_u64().unwrap() > 0);
        assert!(a["processCount"].as_u64().unwrap() > 0);
        assert!(a["handleCount"].as_u64().unwrap() > 0);
        assert!(a["commitLimit"].as_u64().unwrap() > 0);
        // Rates need two samples; the first says so with null.
        assert!(a["cpu"].is_null() && a["perCore"].is_null());
        // Test the cache, independently of how long Windows took to obtain
        // its first process/sensor sample under load.
        monitor.sampled = Some(std::time::Instant::now());
        monitor.processes_at = Some(std::time::Instant::now());
        let b = monitor.snapshot(true).unwrap();
        assert_eq!(a, b);
        assert!(monitor.stop(std::process::id(), 0).is_err());
        assert!(monitor.stop(0, 0).is_err());
    }
    #[cfg(windows)]
    #[test]
    fn temperatures_are_plausible_and_need_no_administrator() {
        // The worker answers from its cache; give it a moment to fill.
        let _ = super::slow_sensors();
        std::thread::sleep(std::time::Duration::from_secs(3));
        let slow = super::slow_sensors();
        eprintln!("temperatures: {:?}
gpus: {:?}", slow.temperatures, slow.gpus);
        for t in &slow.temperatures {
            let c = t["celsius"].as_f64().unwrap();
            assert!((-20.0..=150.0).contains(&c));
        }
        if let Some(zones) = super::ThermalZones::open() {
            // A machine without ACPI zones lists none, never a zero.
            assert!(zones.read().iter().all(|z| z["celsius"].as_f64().unwrap() != 0.0));
        }
    }
}
