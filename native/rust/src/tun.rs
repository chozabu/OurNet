//! Virtual network interfaces for plugins granted `tun` (a VPN). Packets
//! move between the system and the plugin's thread here, without crossing
//! into Dart: only what the plugin sends to friends does.
//!
//! The app decides how an interface is made, since that is where the person
//! is asked: Android's VpnService hands over a file descriptor; on Windows
//! this opens a Wintun adapter (wintun.dll beside the app, administrator
//! rights); tests use a memory interface whose packets go to Dart.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// Packets the system sent; returns false once nobody wants them.
pub type Deliver = Box<dyn FnMut(Vec<u8>) -> bool + Send>;

/// How the app said to make the interface.
pub enum Kind {
    /// A descriptor the system gave the app (Android).
    #[allow(dead_code)]
    Fd(i32),
    /// A Wintun adapter with this name.
    #[allow(dead_code)]
    Wintun(String),
    /// Packets are handed to [write] instead (tests).
    Memory,
}

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
    Wintun(Arc<wintun::Session>),
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
                        let mut buf = vec![0u8; mtu.max(1500) + 64];
                        while !stopped.load(Ordering::Relaxed) {
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
            Kind::Wintun(name) => {
                let session = wintun_open(&name, config)?;
                let reader = session.clone();
                let stopped = stop.clone();
                std::thread::Builder::new()
                    .name("ournet-tun".into())
                    .spawn(move || {
                        while !stopped.load(Ordering::Relaxed) {
                            match reader.receive_blocking() {
                                Ok(packet) => {
                                    if !deliver(packet.bytes().to_vec()) {
                                        break;
                                    }
                                }
                                Err(_) => break,
                            }
                        }
                    })
                    .map_err(|e| e.to_string())?;
                Inner::Wintun(session)
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
            Inner::Wintun(session) => {
                if let Ok(len) = u16::try_from(packet.len()) {
                    if let Ok(mut out) = session.allocate_send_packet(len) {
                        out.bytes_mut().copy_from_slice(packet);
                        session.send_packet(out);
                    }
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
        if let Inner::Wintun(session) = &self.inner {
            // Wakes the reader, which then stops.
            let _ = session.shutdown();
        }
    }
}

#[cfg(windows)]
fn wintun_open(name: &str, config: &Config) -> Result<Arc<wintun::Session>, String> {
    let wintun = unsafe { wintun::load() }
        .map_err(|_| "wintun.dll is missing: put it beside OurNet (wintun.net)".to_string())?;
    let adapter = match wintun::Adapter::open(&wintun, name) {
        Ok(a) => a,
        Err(_) => wintun::Adapter::create(&wintun, name, "OurNet", None)
            .map_err(|e| format!("cannot create the adapter (run as administrator?): {e}"))?,
    };
    let mask = if config.prefix == 0 {
        0
    } else {
        u32::MAX << (32 - config.prefix.min(32) as u32)
    };
    adapter
        .set_network_addresses_tuple(
            std::net::IpAddr::V4(config.address),
            std::net::IpAddr::V4(std::net::Ipv4Addr::from(mask)),
            None,
        )
        .map_err(|e| format!("cannot set its address: {e}"))?;
    let _ = adapter.set_mtu(config.mtu as usize);
    for route in config.routes {
        let index = adapter.get_adapter_index().map_err(|e| e.to_string())?;
        let _ = std::process::Command::new("netsh")
            .args([
                "interface",
                "ipv4",
                "add",
                "route",
                route,
                &format!("interface={index}"),
                "store=active",
            ])
            .output();
    }
    adapter
        .start_session(wintun::MAX_RING_CAPACITY)
        .map(Arc::new)
        .map_err(|e| e.to_string())
}
