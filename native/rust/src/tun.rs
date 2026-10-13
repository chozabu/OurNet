//! Virtual network interfaces for plugins granted `tun` (a VPN). Packets
//! move between the system and the plugin's thread here, without crossing
//! into Dart: only what the plugin sends to friends does.
//!
//! The app decides how an interface is made, since that is where the person
//! is asked: Android's VpnService hands over a file descriptor; on Windows
//! the `ournet-tun` helper service (native/tun-helper), installed once with
//! the person's consent, owns a Wintun adapter and passes packets over named
//! pipes, so the app never runs as administrator; tests use a memory
//! interface whose packets go to Dart.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// Packets the system sent; returns false once nobody wants them.
pub type Deliver = Box<dyn FnMut(Vec<u8>) -> bool + Send>;

/// How the app said to make the interface.
pub enum Kind {
    /// A descriptor the system gave the app (Android).
    #[allow(dead_code)]
    Fd(i32),
    /// The Windows helper's pipes, `\\.\pipe\<name>.up` and `.down`.
    #[allow(dead_code)]
    Pipe(String),
    /// Packets are handed to [write] instead (tests).
    Memory,
}

// Android's VpnService sets these itself; the Windows helper is sent them.
#[cfg_attr(not(windows), allow(dead_code))]
pub struct Config<'a> {
    pub address: std::net::Ipv4Addr,
    pub prefix: u8,
    pub routes: &'a [String],
    pub mtu: u16,
}

pub struct Tun {
    stop: Arc<AtomicBool>,
    inner: Inner,
}

enum Inner {
    #[cfg(unix)]
    Fd(std::fs::File),
    #[cfg(windows)]
    Pipe(std::sync::Mutex<std::fs::File>),
    Memory(Box<dyn Fn(&[u8]) + Send>),
}

impl Tun {
    /// Opens the interface and starts handing what the system sends to
    /// [deliver] from a thread of its own. [memory] receives what the plugin
    /// writes to a memory interface.
    pub fn open(
        kind: Kind,
        config: &Config,
        mut deliver: Deliver,
        memory: Box<dyn Fn(&[u8]) + Send>,
    ) -> Result<Tun, String> {
        let stop = Arc::new(AtomicBool::new(false));
        let inner = match kind {
            Kind::Memory => Inner::Memory(memory),
            #[cfg(unix)]
            Kind::Fd(fd) => {
                use std::io::Read;
                use std::os::fd::FromRawFd;
                if fd < 0 {
                    return Err("no interface".into());
                }
                let file = unsafe { std::fs::File::from_raw_fd(fd) };
                let mut reader = file.try_clone().map_err(|e| e.to_string())?;
                let stopped = stop.clone();
                let mtu = config.mtu as usize;
                std::thread::Builder::new()
                    .name("ournet-tun".into())
                    .spawn(move || {
                        use std::os::fd::AsRawFd;
                        let mut buf = vec![0u8; mtu.max(1500) + 64];
                        while !stopped.load(Ordering::Relaxed) {
                            // Waits a little at a time, so closing is noticed
                            // even when nothing arrives.
                            let mut poll = libc::pollfd { fd: reader.as_raw_fd(), events: libc::POLLIN, revents: 0 };
                            match unsafe { libc::poll(&mut poll, 1, 250) } {
                                0 => continue,
                                n if n < 0 => break,
                                _ => {}
                            }
                            match reader.read(&mut buf) {
                                Ok(0) | Err(_) => break,
                                Ok(n) => {
                                    if !deliver(buf[..n].to_vec()) {
                                        break;
                                    }
                                }
                            }
                        }
                    })
                    .map_err(|e| e.to_string())?;
                Inner::Fd(file)
            }
            #[cfg(windows)]
            Kind::Pipe(name) => {
                let (up, mut down) = pipe_open(&name, config)?;
                std::thread::Builder::new()
                    .name("ournet-tun".into())
                    .spawn(move || {
                        // Ends when the helper closes its end, after this
                        // side's `up` is dropped.
                        while let Some((kind, body)) = read_frame(&mut down) {
                            if kind == 2 && !deliver(body) {
                                break;
                            }
                        }
                    })
                    .map_err(|e| e.to_string())?;
                Inner::Pipe(std::sync::Mutex::new(up))
            }
            #[allow(unreachable_patterns)]
            _ => return Err("not available on this system".into()),
        };
        Ok(Tun { stop, inner })
    }

    /// Hands [packet] to the system.
    pub fn write(&self, packet: &[u8]) {
        match &self.inner {
            #[cfg(unix)]
            Inner::Fd(file) => {
                use std::io::Write;
                let mut file = file;
                let _ = file.write(packet);
            }
            #[cfg(windows)]
            Inner::Pipe(up) => {
                if let Ok(mut up) = up.lock() {
                    write_frame(&mut up, 2, packet);
                }
            }
            Inner::Memory(write) => write(packet),
        }
    }
}

impl Drop for Tun {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        #[cfg(windows)]
        if let Inner::Pipe(up) = &self.inner {
            if let Ok(mut up) = up.lock() {
                write_frame(&mut up, 3, &[]);
            }
        }
    }
}

/// The helper's frames: a little-endian u32 length of what follows, a type
/// byte, the body. See native/tun-helper.
#[cfg(windows)]
fn write_frame(out: &mut std::fs::File, kind: u8, body: &[u8]) -> bool {
    use std::io::Write;
    let mut frame = Vec::with_capacity(5 + body.len());
    frame.extend_from_slice(&((body.len() + 1) as u32).to_le_bytes());
    frame.push(kind);
    frame.extend_from_slice(body);
    out.write_all(&frame).is_ok()
}

#[cfg(windows)]
fn read_frame(input: &mut std::fs::File) -> Option<(u8, Vec<u8>)> {
    use std::io::Read;
    let mut head = [0u8; 4];
    input.read_exact(&mut head).ok()?;
    let len = u32::from_le_bytes(head) as usize;
    if len == 0 || len > 1 << 16 {
        return None;
    }
    let mut body = vec![0u8; len];
    input.read_exact(&mut body).ok()?;
    let kind = body.remove(0);
    Some((kind, body))
}

/// Connects to the helper and asks it to open the interface.
#[cfg(windows)]
fn pipe_open(name: &str, config: &Config) -> Result<(std::fs::File, std::fs::File), String> {
    let missing = |e: std::io::Error| format!("the OurNet network helper is not running ({e})");
    let mut up = std::fs::OpenOptions::new()
        .write(true)
        .open(format!(r"\\.\pipe\{name}.up"))
        .map_err(missing)?;
    let mut down = std::fs::OpenOptions::new()
        .read(true)
        .open(format!(r"\\.\pipe\{name}.down"))
        .map_err(missing)?;
    let open = serde_json::json!({
        "address": config.address.to_string(),
        "prefix": config.prefix,
        "routes": config.routes,
        "mtu": config.mtu,
    });
    if !write_frame(&mut up, 1, open.to_string().as_bytes()) {
        return Err("the network helper closed".into());
    }
    match read_frame(&mut down) {
        Some((4, body)) => {
            let status: serde_json::Value = serde_json::from_slice(&body).unwrap_or_default();
            match status.get("error").and_then(|e| e.as_str()) {
                Some(error) => Err(format!("the network helper refused: {error}")),
                None => Ok((up, down)),
            }
        }
        _ => Err("the network helper did not answer".into()),
    }
}
