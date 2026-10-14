//! OurNet's Windows network helper.
//!
//! VPN plugins need a virtual network interface (docs/PLUGINS.md, `tun`). On
//! Windows that is a Wintun adapter, which only an administrator can make.
//! Rather than run the app elevated, this small service runs as SYSTEM and
//! owns the adapter; the app talks to it over two named pipes that only the
//! person who installed it (and administrators) may open. It sets up only
//! addresses and routes inside 10.77.0.0/16: never a default route or DNS,
//! so whoever reaches the pipes cannot take over the machine's networking.
//!
//!     ournet-tun install --user <SID>   (elevated, once: the app asks UAC)
//!     ournet-tun uninstall              (elevated)
//!     ournet-tun version
//!     ournet-tun service <SID>          (run by the service manager)
//!     ournet-tun loopback <pipe> <SID>  (tests: one session without Wintun)
//!
//! The app writes to `\\.\pipe\ournet-tun.up` and reads from
//! `\\.\pipe\ournet-tun.down`. Both carry frames: a little-endian u32 length
//! (of what follows), a type byte, then the body.
//!   up:   1 open `{"address","prefix","routes","mtu"}` · 2 packet · 3 close
//!   down: 2 packet · 4 status `{"ok":true}` or `{"error":"…"}`
//! One session at a time; it ends when the app closes its end.

/// Bumped when the pipe protocol or what the helper allows changes; the app
/// reinstalls a helper older than the one it ships.
const VERSION: u32 = 2;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("version") => println!("{VERSION}"),
        #[cfg(windows)]
        Some(_) => std::process::exit(windows::run(&args)),
        _ => {
            eprintln!("ournet-tun: Windows only");
            std::process::exit(2);
        }
    }
}

/// Whether [ip] is in 10.77.0.0/16.
fn ours(ip: [u8; 4]) -> bool {
    ip[0] == 10 && ip[1] == 77
}

/// A route the helper may add: a CIDR inside 10.77.0.0/16.
fn allowed_route(route: &str) -> Option<([u8; 4], u8)> {
    let (ip, len) = route.split_once('/')?;
    let ip: std::net::Ipv4Addr = ip.parse().ok()?;
    let len: u8 = len.parse().ok()?;
    (ours(ip.octets()) && (16..=32).contains(&len)).then_some((ip.octets(), len))
}

#[cfg(windows)]
mod windows {
    use std::ffi::OsString;
    use std::fs::File;
    use std::io::{Read, Write};
    use std::net::Ipv4Addr;
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::io::FromRawHandle;
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use serde_json::{json, Value};
    use windows_service::service::{
        ServiceAccess, ServiceControl, ServiceControlAccept, ServiceErrorControl, ServiceExitCode, ServiceInfo,
        ServiceStartType, ServiceState, ServiceStatus, ServiceType,
    };
    use windows_service::service_control_handler::{self, ServiceControlHandlerResult};
    use windows_service::service_manager::{ServiceManager, ServiceManagerAccess};
    use windows_service::{define_windows_service, service_dispatcher};
    use windows_sys::Win32::Foundation::{GetLastError, LocalFree, ERROR_PIPE_CONNECTED, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Security::Authorization::{
        ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
    };
    use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
    use windows_sys::Win32::Storage::FileSystem::{PIPE_ACCESS_INBOUND, PIPE_ACCESS_OUTBOUND};
    use windows_sys::Win32::System::Pipes::{
        ConnectNamedPipe, CreateNamedPipeW, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_WAIT,
    };

    use super::{allowed_route, ours, VERSION};

    const SERVICE: &str = "ournet-tun";
    const ADAPTER: &str = "OurNet";
    const UP: &str = r"\\.\pipe\ournet-tun.up";
    const DOWN: &str = r"\\.\pipe\ournet-tun.down";

    pub fn run(args: &[String]) -> i32 {
        let result = match args[0].as_str() {
            "install" => match args.get(1).zip(args.get(2)) {
                Some((flag, sid)) if flag == "--user" && valid_sid(sid) => install(sid),
                _ => Err("usage: ournet-tun install --user <SID>".into()),
            },
            "uninstall" => uninstall(),
            "loopback" => match args.get(1).zip(args.get(2)) {
                Some((name, sid)) if valid_sid(sid) => loopback(name, sid),
                _ => Err("usage: ournet-tun loopback <pipe> <SID>".into()),
            },
            "service" => {
                // The service manager starts it; the dispatcher calls back.
                service_dispatcher::start(SERVICE, ffi_service_main).map_err(|e| e.to_string())
            }
            other => Err(format!("unknown command {other}")),
        };
        match result {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("ournet-tun: {e}");
                1
            }
        }
    }

    fn valid_sid(sid: &str) -> bool {
        sid.starts_with("S-1-") && sid.len() < 200 && sid.chars().all(|c| c.is_ascii_digit() || c == '-' || c == 'S')
    }

    /// Where the helper lives once installed: outside the app's folder,
    /// which moves when the app updates.
    fn home() -> PathBuf {
        let data = std::env::var_os("ProgramData").unwrap_or_else(|| OsString::from(r"C:\ProgramData"));
        PathBuf::from(data).join("OurNet").join("tun")
    }

    fn install(sid: &str) -> Result<(), String> {
        let manager = ServiceManager::local_computer(
            None::<&str>,
            ServiceManagerAccess::CONNECT | ServiceManagerAccess::CREATE_SERVICE,
        )
        .map_err(|e| format!("service manager: {e} (run elevated)"))?;
        // An older helper is stopped before its files are replaced.
        let access = ServiceAccess::QUERY_STATUS | ServiceAccess::STOP | ServiceAccess::START | ServiceAccess::CHANGE_CONFIG;
        let existing = manager.open_service(SERVICE, access).ok();
        if let Some(service) = &existing {
            if service.query_status().map(|s| s.current_state != ServiceState::Stopped).unwrap_or(false) {
                let _ = service.stop();
                for _ in 0..50 {
                    if service.query_status().map(|s| s.current_state == ServiceState::Stopped).unwrap_or(true) {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
            }
        }
        let source = std::env::current_exe().map_err(|e| e.to_string())?;
        let from = source.parent().ok_or("no folder")?;
        let to = home();
        std::fs::create_dir_all(&to).map_err(|e| e.to_string())?;
        for name in ["ournet-tun.exe", "wintun.dll"] {
            std::fs::copy(from.join(name), to.join(name)).map_err(|e| format!("copying {name}: {e}"))?;
        }
        let info = ServiceInfo {
            name: SERVICE.into(),
            display_name: "OurNet network helper".into(),
            service_type: ServiceType::OWN_PROCESS,
            start_type: ServiceStartType::AutoStart,
            error_control: ServiceErrorControl::Normal,
            executable_path: to.join("ournet-tun.exe"),
            launch_arguments: vec!["service".into(), sid.into()],
            dependencies: vec![],
            account_name: None,
            account_password: None,
        };
        let service = match existing {
            Some(service) => {
                service.change_config(&info).map_err(|e| e.to_string())?;
                service
            }
            None => manager.create_service(&info, access).map_err(|e| format!("creating the service: {e}"))?,
        };
        let _ = service.set_description("Gives OurNet plugins a private network (10.77.0.0/16) without running OurNet as administrator.");
        service.start::<&str>(&[]).map_err(|e| format!("starting the service: {e}"))?;
        Ok(())
    }

    fn uninstall() -> Result<(), String> {
        let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
            .map_err(|e| e.to_string())?;
        let service = manager
            .open_service(SERVICE, ServiceAccess::STOP | ServiceAccess::DELETE | ServiceAccess::QUERY_STATUS)
            .map_err(|e| e.to_string())?;
        let _ = service.stop();
        service.delete().map_err(|e| e.to_string())
    }

    /// One session on pipes [name] without an adapter, for tests: it takes
    /// the open request, sends one packet as if from the system, and prints
    /// the first packet sent back as hex.
    fn loopback(name: &str, sid: &str) -> Result<(), String> {
        let up = pipe(&format!(r"\\.\pipe\{name}.up"), true, sid).ok_or("pipe")?;
        let down = pipe(&format!(r"\\.\pipe\{name}.down"), false, sid).ok_or("pipe")?;
        println!("ready");
        let (Some(mut up), Some(down)) = (connect(up), connect(down)) else { return Err("connect".into()) };
        let down = Mutex::new(down);
        let (kind, body) = read_frame(&mut up).ok_or("no open request")?;
        let v: Value = serde_json::from_slice(&body).map_err(|e| e.to_string())?;
        if kind != 1 || v["address"].as_str().map(|a| !a.starts_with("10.77.")).unwrap_or(true) {
            write_frame(&down, 4, br#"{"error":"bad open"}"#);
            return Err("bad open".into());
        }
        write_frame(&down, 4, br#"{"ok":true}"#);
        let packet = [0x45u8, 0, 0, 24, 0, 0, 0, 0, 64, 17, 0, 0, 10, 77, 0, 2, 10, 77, 0, 1, 1, 2, 3, 4];
        write_frame(&down, 2, &packet);
        while let Some((kind, body)) = read_frame(&mut up) {
            if kind == 2 {
                println!("{}", body.iter().map(|b| format!("{b:02x}")).collect::<String>());
                return Ok(());
            }
        }
        Err("nothing came back".into())
    }

    define_windows_service!(ffi_service_main, service_main);

    fn service_main(args: Vec<OsString>) {
        // The service manager passes the configured arguments after the name.
        let sid = args
            .iter()
            .filter_map(|a| a.to_str())
            .find(|a| a.starts_with("S-1-"))
            .map(String::from)
            .or_else(|| std::env::args().find(|a| a.starts_with("S-1-")));
        let handler = service_control_handler::register(SERVICE, |control| match control {
            ServiceControl::Stop | ServiceControl::Shutdown => {
                // The adapter goes with the process.
                std::process::exit(0);
            }
            ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
            _ => ServiceControlHandlerResult::NotImplemented,
        });
        let Ok(handler) = handler else { return };
        let status = |state| ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: state,
            controls_accepted: ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
            exit_code: ServiceExitCode::Win32(0),
            checkpoint: 0,
            wait_hint: Duration::default(),
            process_id: None,
        };
        let _ = handler.set_service_status(status(ServiceState::Running));
        if let Some(sid) = sid.filter(|s| valid_sid(s)) {
            serve(&sid);
        }
        let _ = handler.set_service_status(status(ServiceState::Stopped));
    }

    /// Serves sessions, one at a time, for as long as the service runs.
    fn serve(sid: &str) {
        let mut adapter: Option<Arc<wintun::Adapter>> = None;
        loop {
            // Both exist before either waits, so the app finds the second as
            // soon as it has opened the first.
            let (Some(up), Some(down)) = (pipe(UP, true, sid), pipe(DOWN, false, sid)) else {
                std::thread::sleep(Duration::from_secs(1));
                continue;
            };
            let (Some(up), Some(down)) = (connect(up), connect(down)) else { continue };
            session(up, down, &mut adapter);
        }
    }

    /// A pipe end only SYSTEM, administrators and [sid] may open, not yet
    /// connected. [inbound] is the app-to-helper direction.
    fn pipe(name: &str, inbound: bool, sid: &str) -> Option<File> {
        let sddl: Vec<u16> = format!("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;{sid})")
            .encode_utf16()
            .chain([0])
            .collect();
        let wide: Vec<u16> = std::ffi::OsStr::new(name).encode_wide().chain([0]).collect();
        unsafe {
            let mut descriptor = std::ptr::null_mut();
            if ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut descriptor, std::ptr::null_mut()) == 0 {
                return None;
            }
            let attributes = SECURITY_ATTRIBUTES {
                nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: descriptor,
                bInheritHandle: 0,
            };
            let handle = CreateNamedPipeW(
                wide.as_ptr(),
                if inbound { PIPE_ACCESS_INBOUND } else { PIPE_ACCESS_OUTBOUND },
                PIPE_TYPE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                1 << 20,
                1 << 20,
                0,
                &attributes,
            );
            LocalFree(descriptor as _);
            if handle == INVALID_HANDLE_VALUE {
                return None;
            }
            Some(File::from_raw_handle(handle as _))
        }
    }

    /// Waits for the app to open [pipe].
    fn connect(pipe: File) -> Option<File> {
        use std::os::windows::io::AsRawHandle;
        let connected = unsafe {
            ConnectNamedPipe(pipe.as_raw_handle() as _, std::ptr::null_mut()) != 0
                || GetLastError() == ERROR_PIPE_CONNECTED
        };
        connected.then_some(pipe)
    }

    fn read_frame(up: &mut File) -> Option<(u8, Vec<u8>)> {
        let mut head = [0u8; 4];
        up.read_exact(&mut head).ok()?;
        let len = u32::from_le_bytes(head) as usize;
        if len == 0 || len > 1 << 16 {
            return None;
        }
        let mut body = vec![0u8; len];
        up.read_exact(&mut body).ok()?;
        let kind = body.remove(0);
        Some((kind, body))
    }

    fn write_frame(down: &Mutex<File>, kind: u8, body: &[u8]) -> bool {
        let mut frame = Vec::with_capacity(5 + body.len());
        frame.extend_from_slice(&((body.len() + 1) as u32).to_le_bytes());
        frame.push(kind);
        frame.extend_from_slice(body);
        down.lock().map(|mut d| d.write_all(&frame).is_ok()).unwrap_or(false)
    }

    fn session(mut up: File, down: File, adapter: &mut Option<Arc<wintun::Adapter>>) {
        let down = Arc::new(Mutex::new(down));
        let mut current: Option<Arc<wintun::Session>> = None;
        while let Some((kind, body)) = read_frame(&mut up) {
            match kind {
                1 => {
                    if let Some(s) = current.take() {
                        let _ = s.shutdown();
                    }
                    let reply = match open(&body, adapter) {
                        Ok(session) => {
                            let reader = session.clone();
                            let out = down.clone();
                            std::thread::spawn(move || {
                                while let Ok(packet) = reader.receive_blocking() {
                                    if !write_frame(&out, 2, packet.bytes()) {
                                        break;
                                    }
                                }
                            });
                            current = Some(session);
                            json!({"ok": true, "version": VERSION})
                        }
                        Err(e) => json!({"error": e}),
                    };
                    write_frame(&down, 4, reply.to_string().as_bytes());
                }
                2 => {
                    // Only packets from the network's own addresses go in.
                    let Some(session) = &current else { continue };
                    if body.len() < 20 || body[0] >> 4 != 4 || !ours([body[12], body[13], body[14], body[15]]) {
                        continue;
                    }
                    if let Ok(len) = u16::try_from(body.len()) {
                        if let Ok(mut packet) = session.allocate_send_packet(len) {
                            packet.bytes_mut().copy_from_slice(&body);
                            session.send_packet(packet);
                        }
                    }
                }
                3 => {
                    if let Some(s) = current.take() {
                        let _ = s.shutdown();
                    }
                }
                _ => break,
            }
        }
        if let Some(s) = current.take() {
            let _ = s.shutdown();
        }
    }

    /// Keeps the adapter to its own routes. Left to Windows' defaults it
    /// gets IPv6 with placeholder DNS servers (fec0::…) and a lower metric
    /// than Wi-Fi, so name lookups and IPv6 traffic for the internet are
    /// tried on it first and go nowhere. It carries IPv4 for 10.77.0.0/16
    /// only: no IPv6, no DNS, and the highest metric.
    fn isolate(index: u32) {
        let i = format!("interface={index}");
        let run = |args: &[&str]| {
            let _ = std::process::Command::new("netsh").args(args).output();
        };
        run(&["interface", "ipv6", "set", "interface", &i, "routerdiscovery=disabled", "advertise=disabled"]);
        run(&["interface", "ipv6", "delete", "dnsservers", &format!("name={index}"), "all"]);
        run(&["interface", "ipv4", "set", "dnsservers", &format!("name={index}"), "source=static", "address=none", "register=none", "validate=no"]);
        run(&["interface", "ipv4", "set", "interface", &i, "metric=9000"]);
        run(&["interface", "ipv6", "set", "interface", &i, "metric=9000"]);
        // Unbinds IPv6 from the adapter altogether.
        let _ = std::process::Command::new("powershell")
            .args(["-NoProfile", "-NonInteractive", "-Command", &format!(
                "Get-NetAdapter -InterfaceIndex {index} | Disable-NetAdapterBinding -ComponentID ms_tcpip6"
            )])
            .output();
    }

    /// Opens the adapter as asked, within what the helper allows.
    fn open(body: &[u8], adapter: &mut Option<Arc<wintun::Adapter>>) -> Result<Arc<wintun::Session>, String> {
        let v: Value = serde_json::from_slice(body).map_err(|e| e.to_string())?;
        let address: Ipv4Addr = v["address"].as_str().unwrap_or("").parse().map_err(|_| "bad address")?;
        let prefix = v["prefix"].as_u64().unwrap_or(0) as u8;
        let mtu = v["mtu"].as_u64().unwrap_or(0) as usize;
        if !ours(address.octets()) || !(16..=32).contains(&prefix) || !(576..=9000).contains(&mtu) {
            return Err("only addresses in 10.77.0.0/16".into());
        }
        let routes: Vec<String> = v["routes"]
            .as_array()
            .map(|r| r.iter().filter_map(|x| x.as_str().map(String::from)).collect())
            .unwrap_or_default();
        if routes.len() > 32 || routes.iter().any(|r| allowed_route(r).is_none()) {
            return Err("only routes inside 10.77.0.0/16".into());
        }
        let adapter = match adapter {
            Some(a) => a.clone(),
            None => {
                let here = std::env::current_exe().map_err(|e| e.to_string())?;
                let wintun = unsafe { wintun::load_from_path(here.with_file_name("wintun.dll")) }
                    .map_err(|e| format!("wintun.dll: {e}"))?;
                let a = match wintun::Adapter::open(&wintun, ADAPTER) {
                    Ok(a) => a,
                    Err(_) => wintun::Adapter::create(&wintun, ADAPTER, "OurNet", None).map_err(|e| e.to_string())?,
                };
                *adapter = Some(a.clone());
                a
            }
        };
        let mask = Ipv4Addr::from(u32::MAX << (32 - prefix as u32));
        adapter
            .set_network_addresses_tuple(address.into(), mask.into(), None)
            .map_err(|e| format!("address: {e}"))?;
        let _ = adapter.set_mtu(mtu);
        let index = adapter.get_adapter_index().map_err(|e| e.to_string())?;
        isolate(index);
        for route in &routes {
            let _ = std::process::Command::new("netsh")
                .args(["interface", "ipv4", "add", "route", route, &format!("interface={index}"), "store=active"])
                .output();
        }
        adapter.start_session(wintun::MAX_RING_CAPACITY).map(Arc::new).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_friend_network_is_allowed() {
        assert!(allowed_route("10.77.0.0/16").is_some());
        assert!(allowed_route("10.77.4.0/24").is_some());
        assert!(allowed_route("0.0.0.0/0").is_none());
        assert!(allowed_route("10.0.0.0/8").is_none());
        assert!(allowed_route("10.78.0.0/16").is_none());
        assert!(allowed_route("192.168.1.0/24").is_none());
        assert!(allowed_route("nonsense").is_none());
    }
}
