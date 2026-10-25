//! Remote desktop: screen capture, hardware H.264, decoding for a Flutter
//! texture, and input applied as state (docs/REMOTE_DESKTOP.md).
//!
//! A capture session runs on a thread of its own: DXGI Desktop Duplication,
//! a GPU video processor to NV12 at the stream size, then the adapter's
//! hardware H.264 encoder (the software one where there is none). Encoded
//! frames are posted to Dart already framed for the wire
//! (`[type][u32 length][body]`), so Dart only writes them to the stream.
//! Datagrams from the viewer (input state, acks, keyframe requests) come
//! back through [ournet_desktop_capture_datagram].
//!
//! A view decodes on a thread of its own into a triple buffer of RGBA that
//! the Windows runner's texture reads on Flutter's raster thread; nothing
//! per frame runs on the UI isolate.

use std::collections::{HashMap, VecDeque};
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{json, Value};

/// Posts one message to Dart: the session's handle and a buffer Dart frees
/// with `ournet_free`.
type Post = unsafe extern "C" fn(handle: u64, data: *mut u8, len: usize);

/// Tells the runner a view has a new frame (`MarkTextureFrameAvailable`).
type Notify = unsafe extern "C" fn(context: *mut c_void);

/// Stream frame types, server to viewer.
pub const VIDEO: u8 = 1;
pub const INFO: u8 = 2;
pub const ERROR: u8 = 3;

/// Datagram types, viewer to server.
pub const INPUT: u8 = 1;
pub const ACK: u8 = 2;
pub const KEYFRAME: u8 = 3;

/// Video frame flags.
pub const KEY: u8 = 1;

/// Held keys one input state may name.
const MAX_KEYS: usize = 16;

/// Without an input state for this long, everything held is released: the
/// viewer resends its state every 100 ms while anything is held.
const INPUT_STALE: Duration = Duration::from_millis(1000);

/// Frames a view keeps waiting to decode; more means the decoder has fallen
/// behind, so it drops them and asks for a keyframe.
const VIEW_QUEUE: usize = 32;

/// How a capture starts, from Dart, as JSON.
#[derive(Deserialize, Clone, Debug)]
#[serde(default)]
pub struct Config {
    /// Frames per second, at most.
    pub fps: u32,
    /// Encoder bit rate.
    pub kbps: u32,
    /// The widest stream sent; larger outputs are scaled down on the GPU.
    pub width: u32,
    /// Which output, primary first.
    pub display: usize,
    /// Frames sent and not yet acknowledged before capture waits.
    pub inflight: u32,
    /// Use the software encoder even where hardware is present (tests).
    pub software: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config { fps: 60, kbps: 20_000, width: 1920, display: 0, inflight: 2, software: false }
    }
}

impl Config {
    fn bounded(mut self) -> Config {
        self.fps = self.fps.clamp(1, 240);
        self.kbps = self.kbps.clamp(500, 200_000);
        self.width = self.width.clamp(320, 7680);
        self.inflight = self.inflight.clamp(1, 8);
        self
    }
}

/// `[type][u32 little-endian length][parts…]`, boxed for Dart.
fn framed(kind: u8, parts: &[&[u8]]) -> Vec<u8> {
    let len: usize = parts.iter().map(|p| p.len()).sum();
    let mut out = Vec::with_capacity(5 + len);
    out.push(kind);
    out.extend_from_slice(&(len as u32).to_le_bytes());
    for p in parts {
        out.extend_from_slice(p);
    }
    out
}

fn post_to(post: Post, handle: u64, bytes: Vec<u8>) {
    let boxed = bytes.into_boxed_slice();
    let len = boxed.len();
    let data = Box::into_raw(boxed) as *mut u8;
    unsafe { post(handle, data, len) };
}

// ───────────────────────────── input state ─────────────────────────────

/// One input state from the viewer: everything held now, not what changed.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct InputState {
    pub seq: u32,
    /// The pointer over the captured output, 0–65535 each way.
    pub x: u16,
    pub y: u16,
    /// Left 1, right 2, middle 4, back 8, forward 16.
    pub buttons: u8,
    /// Running totals in Windows wheel units (120 a notch).
    pub wheel: i32,
    pub hwheel: i32,
    /// USB HID keyboard usages (page 7) held.
    pub keys: Vec<u16>,
}

impl InputState {
    /// `[1][u32 seq][u16 x][u16 y][u8 buttons][i32 wheel][i32 hwheel][u8 n][n × u16]`.
    pub fn parse(data: &[u8]) -> Option<InputState> {
        if data.len() < 19 || data[0] != INPUT {
            return None;
        }
        let u16_at = |i: usize| u16::from_le_bytes([data[i], data[i + 1]]);
        let i32_at = |i: usize| i32::from_le_bytes(data[i..i + 4].try_into().unwrap());
        let n = data[18] as usize;
        if n > MAX_KEYS || data.len() != 19 + 2 * n {
            return None;
        }
        Some(InputState {
            seq: u32::from_le_bytes(data[1..5].try_into().unwrap()),
            x: u16_at(5),
            y: u16_at(7),
            buttons: data[9] & 0x1f,
            wheel: i32_at(10),
            hwheel: i32_at(14),
            keys: (0..n).map(|k| u16_at(19 + 2 * k)).collect(),
        })
    }

    #[cfg(test)]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = vec![INPUT];
        out.extend_from_slice(&self.seq.to_le_bytes());
        out.extend_from_slice(&self.x.to_le_bytes());
        out.extend_from_slice(&self.y.to_le_bytes());
        out.push(self.buttons);
        out.extend_from_slice(&self.wheel.to_le_bytes());
        out.extend_from_slice(&self.hwheel.to_le_bytes());
        out.push(self.keys.len() as u8);
        for k in &self.keys {
            out.extend_from_slice(&k.to_le_bytes());
        }
        out
    }
}

/// What applying a state does to the system, in order.
#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    /// Absolute, 0–65535 over the captured output.
    Move(u16, u16),
    Button(u8, bool),
    Wheel(i32),
    HWheel(i32),
    /// A set-1 scan code (0xE0xx for extended keys), down or up.
    Key(u16, bool),
}

/// The state last applied, and what changes from it.
#[derive(Default)]
pub struct Applied {
    last: Option<InputState>,
}

impl Applied {
    /// The actions that take the system from the last state applied to
    /// [next]. An older or repeated state changes nothing; the first one
    /// sets the wheel totals without scrolling.
    pub fn apply(&mut self, next: InputState) -> Vec<Action> {
        let mut actions = Vec::new();
        let Some(last) = &self.last else {
            actions.push(Action::Move(next.x, next.y));
            for b in 0..5 {
                if next.buttons & (1 << b) != 0 {
                    actions.push(Action::Button(1 << b, true));
                }
            }
            for k in &next.keys {
                if let Some(scan) = scan_code(*k) {
                    actions.push(Action::Key(scan, true));
                }
            }
            self.last = Some(next);
            return actions;
        };
        // Sequence numbers wrap; anything not ahead is old.
        if next.seq.wrapping_sub(last.seq) as i32 <= 0 {
            return actions;
        }
        if (next.x, next.y) != (last.x, last.y) {
            actions.push(Action::Move(next.x, next.y));
        }
        // Keys released first, so a chord changing hands never overlaps.
        for k in &last.keys {
            if !next.keys.contains(k) {
                if let Some(scan) = scan_code(*k) {
                    actions.push(Action::Key(scan, false));
                }
            }
        }
        for k in &next.keys {
            if !last.keys.contains(k) {
                if let Some(scan) = scan_code(*k) {
                    actions.push(Action::Key(scan, true));
                }
            }
        }
        for b in 0..5 {
            let bit = 1u8 << b;
            if (next.buttons ^ last.buttons) & bit != 0 {
                actions.push(Action::Button(bit, next.buttons & bit != 0));
            }
        }
        let wheel = next.wheel.wrapping_sub(last.wheel).clamp(-1200, 1200);
        if wheel != 0 {
            actions.push(Action::Wheel(wheel));
        }
        let hwheel = next.hwheel.wrapping_sub(last.hwheel).clamp(-1200, 1200);
        if hwheel != 0 {
            actions.push(Action::HWheel(hwheel));
        }
        self.last = Some(next);
        actions
    }

    /// Releases everything held, keeping where the pointer is.
    pub fn release(&mut self) -> Vec<Action> {
        let Some(last) = &mut self.last else {
            return Vec::new();
        };
        let mut actions = Vec::new();
        for k in last.keys.drain(..) {
            if let Some(scan) = scan_code(k) {
                actions.push(Action::Key(scan, false));
            }
        }
        for b in 0..5 {
            let bit = 1u8 << b;
            if last.buttons & bit != 0 {
                actions.push(Action::Button(bit, false));
            }
        }
        last.buttons = 0;
        actions
    }

    pub fn holding(&self) -> bool {
        self.last.as_ref().is_some_and(|s| s.buttons != 0 || !s.keys.is_empty())
    }
}

/// The set-1 scan code of a USB HID keyboard usage; extended keys carry
/// 0xE0 in the high byte. None for usages with no PC key.
pub fn scan_code(usage: u16) -> Option<u16> {
    let code = match usage {
        0x04..=0x1d => {
            // a–z
            const LETTERS: [u16; 26] = [
                0x1e, 0x30, 0x2e, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32, 0x31,
                0x18, 0x19, 0x10, 0x13, 0x1f, 0x14, 0x16, 0x2f, 0x11, 0x2d, 0x15, 0x2c,
            ];
            LETTERS[(usage - 0x04) as usize]
        }
        0x1e..=0x26 => usage - 0x1e + 0x02, // 1–9
        0x27 => 0x0b,                       // 0
        0x28 => 0x1c,                       // Enter
        0x29 => 0x01,                       // Escape
        0x2a => 0x0e,                       // Backspace
        0x2b => 0x0f,                       // Tab
        0x2c => 0x39,                       // Space
        0x2d => 0x0c,                       // -
        0x2e => 0x0d,                       // =
        0x2f => 0x1a,                       // [
        0x30 => 0x1b,                       // ]
        0x31 => 0x2b,                       // backslash
        0x32 => 0x2b,                       // non-US #
        0x33 => 0x27,                       // ;
        0x34 => 0x28,                       // '
        0x35 => 0x29,                       // `
        0x36 => 0x33,                       // ,
        0x37 => 0x34,                       // .
        0x38 => 0x35,                       // /
        0x39 => 0x3a,                       // Caps Lock
        0x3a..=0x43 => usage - 0x3a + 0x3b, // F1–F10
        0x44 => 0x57,                       // F11
        0x45 => 0x58,                       // F12
        0x46 => 0xe037,                     // Print Screen
        0x47 => 0x46,                       // Scroll Lock
        0x49 => 0xe052,                     // Insert
        0x4a => 0xe047,                     // Home
        0x4b => 0xe049,                     // Page Up
        0x4c => 0xe053,                     // Delete
        0x4d => 0xe04f,                     // End
        0x4e => 0xe051,                     // Page Down
        0x4f => 0xe04d,                     // Right
        0x50 => 0xe04b,                     // Left
        0x51 => 0xe050,                     // Down
        0x52 => 0xe048,                     // Up
        0x53 => 0x45,                       // Num Lock
        0x54 => 0xe035,                     // keypad /
        0x55 => 0x37,                       // keypad *
        0x56 => 0x4a,                       // keypad -
        0x57 => 0x4e,                       // keypad +
        0x58 => 0xe01c,                     // keypad Enter
        0x59 => 0x4f,                       // keypad 1
        0x5a => 0x50,
        0x5b => 0x51,
        0x5c => 0x4b,
        0x5d => 0x4c,
        0x5e => 0x4d,
        0x5f => 0x47,
        0x60 => 0x48,
        0x61 => 0x49,                       // keypad 9
        0x62 => 0x52,                       // keypad 0
        0x63 => 0x53,                       // keypad .
        0x64 => 0x56,                       // non-US backslash
        0x65 => 0xe05d,                     // Menu
        0x68..=0x73 => [0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x76][(usage - 0x68) as usize], // F13–F24
        0xe0 => 0x1d,                       // Left Ctrl
        0xe1 => 0x2a,                       // Left Shift
        0xe2 => 0x38,                       // Left Alt
        0xe3 => 0xe05b,                     // Left Windows
        0xe4 => 0xe01d,                     // Right Ctrl
        0xe5 => 0x36,                       // Right Shift
        0xe6 => 0xe038,                     // Right Alt
        0xe7 => 0xe05c,                     // Right Windows
        _ => return None,
    };
    Some(code)
}

// ─────────────────────────────── colour ───────────────────────────────

/// NV12 (BT.709, studio range, as the capture's video processor writes it)
/// to RGBA, rows split across threads for large frames.
pub fn nv12_to_rgba(y: &[u8], uv: &[u8], pitch: usize, width: usize, height: usize, out: &mut [u8]) {
    #[inline(always)]
    fn pixel(y: u8, d: i32, e: i32, p: &mut [u8]) {
        // BT.709 studio range in 8.8 fixed point.
        let c = (y as i32 - 16).max(0) * 298;
        p[0] = ((c + 459 * e + 128) >> 8).clamp(0, 255) as u8;
        p[1] = ((c - 55 * d - 136 * e + 128) >> 8).clamp(0, 255) as u8;
        p[2] = ((c + 541 * d + 128) >> 8).clamp(0, 255) as u8;
        p[3] = 255;
    }
    let rows = |out: &mut [u8], first: usize| {
        for (r, line) in out.chunks_exact_mut(width * 4).enumerate() {
            let row = first + r;
            let ys = &y[row * pitch..row * pitch + width];
            let uvs = &uv[(row / 2) * pitch..(row / 2) * pitch + (width & !1)];
            let pairs = width / 2;
            for ((px, yy), c) in line[..pairs * 8].chunks_exact_mut(8).zip(ys.chunks_exact(2)).zip(uvs.chunks_exact(2)) {
                let (d, e) = (c[0] as i32 - 128, c[1] as i32 - 128);
                let (a, b) = px.split_at_mut(4);
                pixel(yy[0], d, e, a);
                pixel(yy[1], d, e, b);
            }
            if width % 2 == 1 {
                pixel(ys[width - 1], 0, 0, &mut line[(width - 1) * 4..]);
            }
        }
    };
    let out = &mut out[..width * height * 4];
    let parts = if width * height >= 1 << 20 { 4 } else { 1 };
    if parts == 1 {
        rows(out, 0);
        return;
    }
    // Strips of even rows, so each shares no chroma row with another.
    let strip = ((height + parts - 1) / parts + 1) & !1;
    thread::scope(|s| {
        for (i, chunk) in out.chunks_mut(strip * width * 4).enumerate() {
            let rows = &rows;
            s.spawn(move || rows(chunk, i * strip));
        }
    });
}

// ────────────────────────────── sessions ──────────────────────────────

struct Capture {
    stop: AtomicBool,
    /// Newest frame ID the viewer has received.
    acked: AtomicU32,
    keyframe: AtomicBool,
    input: Mutex<Option<Sender<InputState>>>,
    /// When each frame not yet acknowledged was captured, oldest first.
    sent: Mutex<VecDeque<(u32, Instant)>>,
    /// From capture to the viewer's ack, smoothed: what the person feels,
    /// less decoding and display, plus the ack's way back.
    latency_us: AtomicU64,
}

impl Capture {
    fn acked(&self, id: u32) {
        // Newest wins; IDs wrap.
        let newer = self
            .acked
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |old| (id.wrapping_sub(old) as i32 > 0).then_some(id))
            .is_ok();
        if !newer {
            return;
        }
        let Ok(mut sent) = self.sent.lock() else { return };
        while let Some(&(frame, at)) = sent.front() {
            if frame.wrapping_sub(id) as i32 > 0 {
                break;
            }
            sent.pop_front();
            if frame == id {
                let us = at.elapsed().as_micros() as u64;
                let old = self.latency_us.load(Ordering::Relaxed);
                self.latency_us.store(if old == 0 { us } else { (old * 4 + us) / 5 }, Ordering::Relaxed);
            }
        }
    }
}

static CAPTURES: Mutex<Option<HashMap<u64, Arc<Capture>>>> = Mutex::new(None);
static VIEWS: Mutex<Option<HashMap<u64, Arc<View>>>> = Mutex::new(None);
static NEXT: AtomicU64 = AtomicU64::new(1);

fn capture(handle: u64) -> Option<Arc<Capture>> {
    CAPTURES.lock().ok()?.as_ref()?.get(&handle).cloned()
}

fn view(handle: u64) -> Option<Arc<View>> {
    VIEWS.lock().ok()?.as_ref()?.get(&handle).cloned()
}

/// A decoded picture: RGBA rows, tightly packed.
#[derive(Default)]
struct Picture {
    rgba: Vec<u8>,
    width: u32,
    height: u32,
}

#[derive(Default)]
struct Buffers {
    /// What the texture last read; only the reader touches it.
    front: Picture,
    /// The newest decoded, not yet read.
    ready: Option<Picture>,
    /// A buffer to decode the next picture into.
    spare: Option<Picture>,
}

struct View {
    frames: Mutex<Option<SyncSender<Vec<u8>>>>,
    queued: AtomicU32,
    buffers: Mutex<Buffers>,
    notify: Mutex<Option<(Notify, usize)>>,
    decoded: AtomicU64,
    /// Width in the high half, height in the low.
    size: AtomicU64,
    wants_key: AtomicBool,
    /// Microseconds the last frame took to decode and convert.
    decode_us: AtomicU64,
    error: Mutex<String>,
}

impl View {
    fn publish(&self, picture: Picture) {
        self.size
            .store(((picture.width as u64) << 32) | picture.height as u64, Ordering::Relaxed);
        if let Ok(mut b) = self.buffers.lock() {
            if let Some(old) = b.ready.replace(picture) {
                b.spare = Some(old);
            }
        }
        self.decoded.fetch_add(1, Ordering::Relaxed);
        if let Ok(n) = self.notify.lock() {
            if let Some((notify, context)) = *n {
                unsafe { notify(context as *mut c_void) };
            }
        }
    }

    fn spare(&self) -> Picture {
        self.buffers.lock().ok().and_then(|mut b| b.spare.take()).unwrap_or_default()
    }

    fn fail(&self, error: String) {
        if let Ok(mut e) = self.error.lock() {
            *e = error;
        }
        self.wants_key.store(true, Ordering::Relaxed);
    }
}

fn run_view(view: Arc<View>, frames: Receiver<Vec<u8>>) {
    #[cfg(windows)]
    win::decode_loop(view, frames);
    #[cfg(not(windows))]
    {
        drop(frames);
        view.fail("Remote desktop viewing needs Windows for now".into());
    }
}

fn run_input(capture: Arc<Capture>, states: Receiver<InputState>, geometry: Arc<Mutex<Option<Geometry>>>) {
    let mut applied = Applied::default();
    loop {
        let actions = match states.recv_timeout(INPUT_STALE) {
            Ok(state) => applied.apply(state),
            Err(RecvTimeoutError::Timeout) if applied.holding() => applied.release(),
            Err(RecvTimeoutError::Timeout) => {
                if capture.stop.load(Ordering::Relaxed) {
                    break;
                }
                continue;
            }
            Err(RecvTimeoutError::Disconnected) => break,
        };
        let geometry = geometry.lock().ok().and_then(|g| *g);
        if let Some(geometry) = geometry {
            inject(&actions, geometry);
        }
    }
    let geometry = geometry.lock().ok().and_then(|g| *g);
    if let Some(geometry) = geometry {
        inject(&applied.release(), geometry);
    }
}

/// Where the captured output sits on the virtual desktop, in pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Geometry {
    pub output: (i32, i32, i32, i32),
    pub desktop: (i32, i32, i32, i32),
}

impl Geometry {
    /// 0–65535 over the output to 0–65535 over the virtual desktop, as
    /// `MOUSEEVENTF_VIRTUALDESK` reads it.
    pub fn absolute(&self, x: u16, y: u16) -> (i32, i32) {
        let (ol, ot, or, ob) = self.output;
        let (dl, dt, dr, db) = self.desktop;
        let px = ol as i64 + (x as i64 * (or - ol - 1).max(0) as i64 + 32767) / 65535;
        let py = ot as i64 + (y as i64 * (ob - ot - 1).max(0) as i64 + 32767) / 65535;
        let nx = ((px - dl as i64) * 65535 + ((dr - dl - 1).max(1) as i64) / 2) / (dr - dl - 1).max(1) as i64;
        let ny = ((py - dt as i64) * 65535 + ((db - dt - 1).max(1) as i64) / 2) / (db - dt - 1).max(1) as i64;
        (nx.clamp(0, 65535) as i32, ny.clamp(0, 65535) as i32)
    }
}

#[cfg(windows)]
fn inject(actions: &[Action], geometry: Geometry) {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::*;
    if actions.is_empty() {
        return;
    }
    let mouse = |dx: i32, dy: i32, data: i32, flags: u32| INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT { dx, dy, mouseData: data as u32, dwFlags: flags, time: 0, dwExtraInfo: 0 },
        },
    };
    let mut events = Vec::with_capacity(actions.len());
    for action in actions {
        events.push(match *action {
            Action::Move(x, y) => {
                let (nx, ny) = geometry.absolute(x, y);
                mouse(nx, ny, 0, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK)
            }
            Action::Button(bit, down) => {
                let (flags, data) = match (bit, down) {
                    (1, true) => (MOUSEEVENTF_LEFTDOWN, 0),
                    (1, false) => (MOUSEEVENTF_LEFTUP, 0),
                    (2, true) => (MOUSEEVENTF_RIGHTDOWN, 0),
                    (2, false) => (MOUSEEVENTF_RIGHTUP, 0),
                    (4, true) => (MOUSEEVENTF_MIDDLEDOWN, 0),
                    (4, false) => (MOUSEEVENTF_MIDDLEUP, 0),
                    (8, true) => (MOUSEEVENTF_XDOWN, 1),
                    (8, false) => (MOUSEEVENTF_XUP, 1),
                    (_, true) => (MOUSEEVENTF_XDOWN, 2),
                    (_, false) => (MOUSEEVENTF_XUP, 2),
                };
                mouse(0, 0, data, flags)
            }
            Action::Wheel(n) => mouse(0, 0, n, MOUSEEVENTF_WHEEL),
            Action::HWheel(n) => mouse(0, 0, n, MOUSEEVENTF_HWHEEL),
            Action::Key(scan, down) => {
                let mut flags = KEYEVENTF_SCANCODE;
                if scan > 0xff {
                    flags |= KEYEVENTF_EXTENDEDKEY;
                }
                if !down {
                    flags |= KEYEVENTF_KEYUP;
                }
                INPUT {
                    r#type: INPUT_KEYBOARD,
                    Anonymous: INPUT_0 {
                        ki: KEYBDINPUT { wVk: 0, wScan: scan & 0xff, dwFlags: flags, time: 0, dwExtraInfo: 0 },
                    },
                }
            }
        });
    }
    // Refusals (an elevated window in front, the secure desktop) are the
    // system's to make; the viewer sees nothing happen, as at a console.
    unsafe { SendInput(events.len() as u32, events.as_ptr(), std::mem::size_of::<INPUT>() as i32) };
}

#[cfg(not(windows))]
fn inject(_: &[Action], _: Geometry) {}

fn run_capture(handle: u64, post: Post, config: Config, capture: Arc<Capture>, geometry: Arc<Mutex<Option<Geometry>>>) {
    #[cfg(windows)]
    let result = win::capture_loop(handle, post, &config, &capture, &geometry);
    #[cfg(not(windows))]
    let result: Result<(), String> = {
        let _ = (&config, &geometry);
        Err("Remote desktop needs a Windows receiver for now".into())
    };
    if let Err(error) = result {
        let body = json!({"error": error}).to_string();
        post_to(post, handle, framed(ERROR, &[body.as_bytes()]));
    }
    capture.stop.store(true, Ordering::Relaxed);
    if let Ok(mut i) = capture.input.lock() {
        i.take();
    }
    // The end: an empty message.
    post_to(post, handle, Vec::new());
}

/// Figures the capture reports once a second.
struct Stats {
    began: Instant,
    last: Instant,
    frames: u32,
    bytes: u64,
    skipped: u32,
    /// Capture, conversion and encoding of the latest frame.
    encode_ms: f64,
}

impl Stats {
    fn new() -> Stats {
        let now = Instant::now();
        Stats { began: now, last: now, frames: 0, bytes: 0, skipped: 0, encode_ms: 0.0 }
    }

    /// The figures, when a second has passed since the last.
    fn report(&mut self, fields: Value, latency_us: u64) -> Option<Value> {
        let elapsed = self.last.elapsed().as_secs_f64();
        if elapsed < 1.0 {
            return None;
        }
        let mut out = json!({
            "fps": (self.frames as f64 / elapsed * 10.0).round() / 10.0,
            "kbps": (self.bytes as f64 * 8.0 / 1000.0 / elapsed).round(),
            "latency": (latency_us as f64 / 100.0).round() / 10.0,
            "skipped": self.skipped,
            "encodeMs": (self.encode_ms * 100.0).round() / 100.0,
        });
        if let (Value::Object(o), Value::Object(f)) = (&mut out, fields) {
            o.extend(f);
        }
        self.last = Instant::now();
        self.frames = 0;
        self.bytes = 0;
        self.skipped = 0;
        Some(out)
    }
}

// ─────────────────────────────── Windows ───────────────────────────────

#[cfg(windows)]
mod win {
    use super::*;
    use std::mem::ManuallyDrop;
    use windows::core::{Interface, PWSTR};
    use windows::Win32::Foundation::{HMODULE, LUID, RECT};
    use windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE_UNKNOWN, D3D_FEATURE_LEVEL_11_0};
    use windows::Win32::Graphics::Direct3D11::*;
    use windows::Win32::Graphics::Dxgi::Common::*;
    use windows::Win32::Graphics::Dxgi::*;
    use windows::Win32::Media::MediaFoundation::*;
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
    use windows::Win32::System::Variant::{VARIANT, VT_BOOL, VT_UI4};

    type Result<T> = std::result::Result<T, String>;

    fn e(context: &str) -> impl Fn(windows::core::Error) -> String + '_ {
        move |err| format!("{context}: {err}")
    }

    fn startup() {
        unsafe {
            // Physical pixels for capture and pointer geometry, whatever the
            // process declared; DuplicateOutput1 requires it too.
            windows_sys::Win32::UI::HiDpi::SetThreadDpiAwarenessContext(
                windows_sys::Win32::UI::HiDpi::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
            );
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let _ = MFStartup(MF_VERSION, MFSTARTUP_FULL);
        }
    }

    fn variant_u32(v: u32) -> VARIANT {
        let mut var = VARIANT::default();
        unsafe {
            (*var.Anonymous.Anonymous).vt = VT_UI4;
            (*var.Anonymous.Anonymous).Anonymous.ulVal = v;
        }
        var
    }

    fn variant_bool(v: bool) -> VARIANT {
        let mut var = VARIANT::default();
        unsafe {
            (*var.Anonymous.Anonymous).vt = VT_BOOL;
            (*var.Anonymous.Anonymous).Anonymous.boolVal =
                windows::Win32::Foundation::VARIANT_BOOL(if v { -1 } else { 0 });
        }
        var
    }

    fn pack(a: u32, b: u32) -> u64 {
        ((a as u64) << 32) | b as u64
    }

    // ── outputs ──

    struct Output {
        adapter: IDXGIAdapter1,
        output: IDXGIOutput1,
        rect: RECT,
        luid: LUID,
    }

    /// Attached outputs, primary first, and the virtual desktop's bounds.
    fn outputs() -> Result<(Vec<Output>, RECT)> {
        let factory: IDXGIFactory1 = unsafe { CreateDXGIFactory1() }.map_err(e("DXGI"))?;
        let mut found = Vec::new();
        let mut desktop = RECT { left: i32::MAX, top: i32::MAX, right: i32::MIN, bottom: i32::MIN };
        for a in 0.. {
            let Ok(adapter) = (unsafe { factory.EnumAdapters1(a) }) else { break };
            let luid = unsafe { adapter.GetDesc1() }.map(|d| d.AdapterLuid).unwrap_or_default();
            for o in 0.. {
                let Ok(output) = (unsafe { adapter.EnumOutputs(o) }) else { break };
                let Ok(desc) = (unsafe { output.GetDesc() }) else { continue };
                if !desc.AttachedToDesktop.as_bool() {
                    continue;
                }
                let r = desc.DesktopCoordinates;
                desktop.left = desktop.left.min(r.left);
                desktop.top = desktop.top.min(r.top);
                desktop.right = desktop.right.max(r.right);
                desktop.bottom = desktop.bottom.max(r.bottom);
                if let Ok(output) = output.cast::<IDXGIOutput1>() {
                    found.push(Output { adapter: adapter.clone(), output, rect: r, luid });
                }
            }
        }
        if found.is_empty() {
            return Err("No display to capture".into());
        }
        found.sort_by_key(|o| !(o.rect.left == 0 && o.rect.top == 0));
        Ok((found, desktop))
    }

    // ── GPU ──

    struct Gpu {
        device: ID3D11Device,
        context: ID3D11DeviceContext,
        video: ID3D11VideoDevice,
        video_context: ID3D11VideoContext,
    }

    impl Gpu {
        fn new(adapter: &IDXGIAdapter1) -> Result<Gpu> {
            let mut device = None;
            let mut context = None;
            unsafe {
                D3D11CreateDevice(
                    adapter,
                    D3D_DRIVER_TYPE_UNKNOWN,
                    HMODULE::default(),
                    D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                    Some(&[D3D_FEATURE_LEVEL_11_0]),
                    D3D11_SDK_VERSION,
                    Some(&mut device),
                    None,
                    Some(&mut context),
                )
            }
            .map_err(e("Direct3D 11"))?;
            let device = device.ok_or("No Direct3D device")?;
            let context = context.ok_or("No Direct3D context")?;
            // Media Foundation uses the device from its own threads.
            if let Ok(mt) = device.cast::<ID3D11Multithread>() {
                unsafe {
                    let _ = mt.SetMultithreadProtected(true);
                }
            }
            let video = device.cast::<ID3D11VideoDevice>().map_err(e("Video device"))?;
            let video_context = context.cast::<ID3D11VideoContext>().map_err(e("Video context"))?;
            Ok(Gpu { device, context, video, video_context })
        }

        fn texture(&self, width: u32, height: u32, format: DXGI_FORMAT, bind: D3D11_BIND_FLAG, usage: D3D11_USAGE, cpu: u32) -> Result<ID3D11Texture2D> {
            let desc = D3D11_TEXTURE2D_DESC {
                Width: width,
                Height: height,
                MipLevels: 1,
                ArraySize: 1,
                Format: format,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: usage,
                BindFlags: bind.0 as u32,
                CPUAccessFlags: cpu,
                MiscFlags: 0,
            };
            let mut texture = None;
            unsafe { self.device.CreateTexture2D(&desc, None, Some(&mut texture)) }.map_err(e("Texture"))?;
            texture.ok_or_else(|| "No texture".into())
        }
    }

    /// BGRA desktop to NV12 at the stream size, on the GPU.
    struct Converter {
        enumerator: ID3D11VideoProcessorEnumerator,
        processor: ID3D11VideoProcessor,
        outputs: Vec<(ID3D11Texture2D, ID3D11VideoProcessorOutputView)>,
        /// The captured frame's copy, and the processor's view of it.
        source: Option<(ID3D11Texture2D, ID3D11VideoProcessorInputView)>,
    }

    impl Converter {
        fn new(gpu: &Gpu, (iw, ih): (u32, u32), (ow, oh): (u32, u32), ring: usize) -> Result<Converter> {
            let desc = D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
                InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
                InputFrameRate: DXGI_RATIONAL { Numerator: 60, Denominator: 1 },
                InputWidth: iw,
                InputHeight: ih,
                OutputFrameRate: DXGI_RATIONAL { Numerator: 60, Denominator: 1 },
                OutputWidth: ow,
                OutputHeight: oh,
                Usage: D3D11_VIDEO_USAGE_OPTIMAL_SPEED,
            };
            let enumerator = unsafe { gpu.video.CreateVideoProcessorEnumerator(&desc) }.map_err(e("Video processor"))?;
            let processor = unsafe { gpu.video.CreateVideoProcessor(&enumerator, 0) }.map_err(e("Video processor"))?;
            unsafe {
                let vc = &gpu.video_context;
                // RGB in at full range; BT.709 studio range out, which the
                // viewer's conversion assumes.
                vc.VideoProcessorSetStreamColorSpace(&processor, 0, &D3D11_VIDEO_PROCESSOR_COLOR_SPACE { _bitfield: 0 });
                vc.VideoProcessorSetOutputColorSpace(&processor, &D3D11_VIDEO_PROCESSOR_COLOR_SPACE { _bitfield: (1 << 2) | (1 << 4) });
                vc.VideoProcessorSetStreamFrameFormat(&processor, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
                vc.VideoProcessorSetStreamOutputRate(&processor, 0, D3D11_VIDEO_PROCESSOR_OUTPUT_RATE_NORMAL, false, None);
                vc.VideoProcessorSetStreamAutoProcessingMode(&processor, 0, false);
                let source = RECT { left: 0, top: 0, right: iw as i32, bottom: ih as i32 };
                let target = RECT { left: 0, top: 0, right: ow as i32, bottom: oh as i32 };
                vc.VideoProcessorSetStreamSourceRect(&processor, 0, true, Some(&source));
                vc.VideoProcessorSetStreamDestRect(&processor, 0, true, Some(&target));
                vc.VideoProcessorSetOutputTargetRect(&processor, true, Some(&target));
            }
            let mut outputs = Vec::new();
            for _ in 0..ring {
                let texture = gpu.texture(ow, oh, DXGI_FORMAT_NV12, D3D11_BIND_RENDER_TARGET, D3D11_USAGE_DEFAULT, 0)?;
                let desc = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC {
                    ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D,
                    Anonymous: D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPOV { MipSlice: 0 } },
                };
                let mut view = None;
                unsafe { gpu.video.CreateVideoProcessorOutputView(&texture, &enumerator, &desc, Some(&mut view)) }
                    .map_err(e("Output view"))?;
                outputs.push((texture, view.ok_or("No output view")?));
            }
            Ok(Converter { enumerator, processor, outputs, source: None })
        }

        /// Copies the captured frame aside (so it can be released at
        /// once), then converts it into NV12 slot [slot]. False for a frame
        /// the processor cannot read: DXGI may hand over a frame or two in
        /// the desktop's own (FP16) format before converting to the 8-bit
        /// BGRA asked for.
        fn convert(&mut self, gpu: &Gpu, captured: &ID3D11Texture2D, slot: usize) -> Result<bool> {
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            unsafe { captured.GetDesc(&mut desc) };
            if desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM {
                return Ok(false);
            }
            if self.source.is_none() {
                let texture = gpu.texture(desc.Width, desc.Height, desc.Format, D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE, D3D11_USAGE_DEFAULT, 0)?;
                let view_desc = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC {
                    FourCC: 0,
                    ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D,
                    Anonymous: D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPIV { MipSlice: 0, ArraySlice: 0 } },
                };
                let mut input = None;
                unsafe { gpu.video.CreateVideoProcessorInputView(&texture, &self.enumerator, &view_desc, Some(&mut input)) }
                    .map_err(e("Input view"))?;
                self.source = Some((texture, input.ok_or("No input view")?));
            }
            let (texture, input) = self.source.as_ref().unwrap();
            unsafe { gpu.context.CopyResource(texture, captured) };
            let stream = D3D11_VIDEO_PROCESSOR_STREAM {
                Enable: true.into(),
                pInputSurface: ManuallyDrop::new(Some(input.clone())),
                ..Default::default()
            };
            let mut streams = [stream];
            let result = unsafe { gpu.video_context.VideoProcessorBlt(&self.processor, &self.outputs[slot].1, 0, &streams) };
            unsafe { ManuallyDrop::drop(&mut streams[0].pInputSurface) };
            result.map_err(e("Convert")).map(|()| true)
        }
    }

    // ── encoder ──

    struct Encoder {
        mft: IMFTransform,
        codec: Option<ICodecAPI>,
        events: Option<IMFMediaEventGenerator>,
        name: String,
        hardware: bool,
        need_input: u32,
        provides: bool,
        size: (u32, u32),
        /// For the software encoder: an NV12 copy the CPU can read.
        staging: Option<ID3D11Texture2D>,
        sequence_header: Vec<u8>,
        _manager: Option<IMFDXGIDeviceManager>,
    }

    fn friendly_name(activate: &IMFActivate) -> String {
        unsafe {
            let mut name = PWSTR::null();
            let mut len = 0;
            if activate.GetAllocatedString(&MFT_FRIENDLY_NAME_Attribute, &mut name, &mut len).is_err() {
                return String::new();
            }
            let text = name.to_string().unwrap_or_default();
            CoTaskMemFree(Some(name.0 as *const c_void));
            text
        }
    }

    impl Encoder {
        fn hardware(gpu: &Gpu, luid: LUID, size: (u32, u32), config: &Config) -> Result<Encoder> {
            let mut attributes = None;
            unsafe { MFCreateAttributes(&mut attributes, 1) }.map_err(e("Attributes"))?;
            let attributes = attributes.ok_or("No attributes")?;
            let luid_bytes: [u8; 8] = unsafe { std::mem::transmute(luid) };
            unsafe { attributes.SetBlob(&MFT_ENUM_ADAPTER_LUID, &luid_bytes) }.map_err(e("Adapter"))?;
            let output = MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: MFVideoFormat_H264 };
            let mut list: *mut Option<IMFActivate> = std::ptr::null_mut();
            let mut count = 0u32;
            unsafe {
                MFTEnum2(
                    MFT_CATEGORY_VIDEO_ENCODER,
                    MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                    None,
                    Some(&output),
                    &attributes,
                    &mut list,
                    &mut count,
                )
            }
            .map_err(e("Finding a hardware encoder"))?;
            let activators: Vec<IMFActivate> = unsafe {
                let found = std::slice::from_raw_parts_mut(list, count as usize).iter_mut().filter_map(|a| a.take()).collect();
                CoTaskMemFree(Some(list as *const c_void));
                found
            };
            let mut last_error = String::from("No hardware H.264 encoder on this adapter");
            for activate in activators {
                let name = friendly_name(&activate);
                match unsafe { activate.ActivateObject::<IMFTransform>() } {
                    Ok(mft) => match Encoder::configure(mft, Some(gpu), name.clone(), true, size, config) {
                        Ok(encoder) => return Ok(encoder),
                        Err(error) => last_error = format!("{name}: {error}"),
                    },
                    Err(error) => last_error = format!("{name}: {error}"),
                }
                unsafe {
                    let _ = activate.ShutdownObject();
                }
            }
            Err(last_error)
        }

        fn software(gpu: &Gpu, size: (u32, u32), config: &Config) -> Result<Encoder> {
            let mft: IMFTransform = unsafe { CoCreateInstance(&CLSID_MSH264EncoderMFT, None, CLSCTX_INPROC_SERVER) }
                .map_err(e("Software encoder"))?;
            let mut encoder = Encoder::configure(mft, None, "Microsoft H.264 (software)".into(), false, size, config)?;

            encoder.staging = Some(gpu.texture(size.0, size.1, DXGI_FORMAT_NV12, D3D11_BIND_FLAG(0), D3D11_USAGE_STAGING, D3D11_CPU_ACCESS_READ.0 as u32)?);
            Ok(encoder)
        }

        fn configure(mft: IMFTransform, gpu: Option<&Gpu>, name: String, hardware: bool, (w, h): (u32, u32), config: &Config) -> Result<Encoder> {
            let mut events = None;
            let mut manager = None;
            unsafe {
                if let Ok(attributes) = mft.GetAttributes() {
                    if attributes.GetUINT32(&MF_TRANSFORM_ASYNC).unwrap_or(0) != 0 {
                        attributes.SetUINT32(&MF_TRANSFORM_ASYNC_UNLOCK, 1).map_err(e("Unlock"))?;
                        events = Some(mft.cast::<IMFMediaEventGenerator>().map_err(e("Events"))?);
                    }
                    let _ = attributes.SetUINT32(&MF_LOW_LATENCY, 1);
                }
                if let Some(gpu) = gpu {
                    let mut token = 0;
                    let mut m = None;
                    MFCreateDXGIDeviceManager(&mut token, &mut m).map_err(e("Device manager"))?;
                    let m = m.ok_or("No device manager")?;
                    m.ResetDevice(&gpu.device, token).map_err(e("Device manager"))?;
                    mft.ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, m.as_raw() as usize)
                        .map_err(e("Giving the encoder the GPU"))?;
                    manager = Some(m);
                }
            }
            let codec = mft.cast::<ICodecAPI>().ok();
            let bps = config.kbps * 1000;
            if let Some(codec) = &codec {
                unsafe {
                    // Each is best effort: encoders support different sets.
                    let _ = codec.SetValue(&CODECAPI_AVLowLatencyMode, &variant_bool(true));
                    let _ = codec.SetValue(&CODECAPI_AVEncCommonRateControlMode, &variant_u32(eAVEncCommonRateControlMode_CBR.0 as u32));
                    let _ = codec.SetValue(&CODECAPI_AVEncCommonMeanBitRate, &variant_u32(bps));
                    let _ = codec.SetValue(&CODECAPI_AVEncMPVDefaultBPictureCount, &variant_u32(0));
                    let _ = codec.SetValue(&CODECAPI_AVEncMPVGOPSize, &variant_u32(config.fps * 30));
                }
            }
            unsafe {
                let output = MFCreateMediaType().map_err(e("Media type"))?;
                output.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video).map_err(e("Output type"))?;
                output.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264).map_err(e("Output type"))?;
                output.SetUINT32(&MF_MT_AVG_BITRATE, bps).map_err(e("Output type"))?;
                output.SetUINT64(&MF_MT_FRAME_SIZE, pack(w, h)).map_err(e("Output type"))?;
                output.SetUINT64(&MF_MT_FRAME_RATE, pack(config.fps, 1)).map_err(e("Output type"))?;
                output.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pack(1, 1)).map_err(e("Output type"))?;
                output.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32).map_err(e("Output type"))?;
                output.SetUINT32(&MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High.0 as u32).map_err(e("Output type"))?;
                mft.SetOutputType(0, &output, 0).map_err(e("Output type"))?;
                let input = MFCreateMediaType().map_err(e("Media type"))?;
                input.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video).map_err(e("Input type"))?;
                input.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12).map_err(e("Input type"))?;
                input.SetUINT64(&MF_MT_FRAME_SIZE, pack(w, h)).map_err(e("Input type"))?;
                input.SetUINT64(&MF_MT_FRAME_RATE, pack(config.fps, 1)).map_err(e("Input type"))?;
                input.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pack(1, 1)).map_err(e("Input type"))?;
                input.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32).map_err(e("Input type"))?;
                mft.SetInputType(0, &input, 0).map_err(e("Input type"))?;
            }
            let sequence_header = unsafe {
                mft.GetOutputCurrentType(0).ok().and_then(|t| {
                    let size = t.GetBlobSize(&MF_MT_MPEG_SEQUENCE_HEADER).ok()?;
                    let mut blob = vec![0u8; size as usize];
                    t.GetBlob(&MF_MT_MPEG_SEQUENCE_HEADER, &mut blob, None).ok()?;
                    Some(blob)
                })
            }
            .unwrap_or_default();
            let provides = unsafe { mft.GetOutputStreamInfo(0) }
                .map(|i| i.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES.0) as u32 != 0)
                .unwrap_or(false);
            unsafe {
                mft.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0).map_err(e("Begin streaming"))?;
                mft.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0).map_err(e("Start of stream"))?;
            }
            Ok(Encoder {
                mft,
                codec,
                events,
                name,
                hardware,
                need_input: 0,
                provides,
                size: (w, h),
                staging: None,
                sequence_header,
                _manager: manager,
            })
        }

        /// The sample for NV12 texture [texture]: the texture itself for
        /// hardware, a CPU copy for software.
        fn sample(&self, gpu: &Gpu, texture: &ID3D11Texture2D) -> Result<IMFSample> {
            unsafe {
                let sample = MFCreateSample().map_err(e("Sample"))?;
                let buffer = match &self.staging {
                    None => {
                        let buffer = MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, texture, 0, false).map_err(e("Surface buffer"))?;
                        if let Ok(b2) = buffer.cast::<IMF2DBuffer>() {
                            if let Ok(len) = b2.GetContiguousLength() {
                                let _ = buffer.SetCurrentLength(len);
                            }
                        }
                        buffer
                    }
                    Some(staging) => {
                        let (w, h) = (self.size.0 as usize, self.size.1 as usize);
                        gpu.context.CopyResource(staging, texture);
                        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
                        gpu.context.Map(staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped)).map_err(e("Reading the frame"))?;
                        let len = w * h * 3 / 2;
                        let buffer = MFCreateMemoryBuffer(len as u32).map_err(e("Buffer"))?;
                        let mut out = std::ptr::null_mut();
                        buffer.Lock(&mut out, None, None).map_err(e("Buffer"))?;
                        let src = mapped.pData as *const u8;
                        let pitch = mapped.RowPitch as usize;
                        for row in 0..h + h / 2 {
                            std::ptr::copy_nonoverlapping(src.add(row * pitch), out.add(row * w), w);
                        }
                        let _ = buffer.Unlock();
                        gpu.context.Unmap(staging, 0);
                        buffer.SetCurrentLength(len as u32).map_err(e("Buffer"))?;
                        buffer
                    }
                };
                sample.AddBuffer(&buffer).map_err(e("Sample"))?;
                Ok(sample)
            }
        }

        /// One encoded frame from the encoder, if it has one.
        fn take_output(&mut self) -> Result<Option<(Vec<u8>, bool)>> {
            unsafe {
                let info = self.mft.GetOutputStreamInfo(0).map_err(e("Output info"))?;
                let sample = if self.provides {
                    None
                } else {
                    let s = MFCreateSample().map_err(e("Sample"))?;
                    let b = MFCreateMemoryBuffer(info.cbSize.max(1 << 20)).map_err(e("Buffer"))?;
                    s.AddBuffer(&b).map_err(e("Sample"))?;
                    Some(s)
                };
                let mut buffers = [MFT_OUTPUT_DATA_BUFFER { dwStreamID: 0, pSample: ManuallyDrop::new(sample), dwStatus: 0, pEvents: ManuallyDrop::new(None) }];
                let mut status = 0;
                let result = self.mft.ProcessOutput(0, &mut buffers, &mut status);
                let sample = ManuallyDrop::take(&mut buffers[0].pSample);
                drop(ManuallyDrop::take(&mut buffers[0].pEvents));
                match result {
                    Ok(()) => {}
                    Err(err) if err.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(None),
                    Err(err) if err.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                        let t = self.mft.GetOutputAvailableType(0, 0).map_err(e("Output type"))?;
                        self.mft.SetOutputType(0, &t, 0).map_err(e("Output type"))?;
                        return Ok(None);
                    }
                    Err(err) => return Err(format!("Encoding: {err}")),
                }
                let Some(sample) = sample else { return Ok(None) };
                let key = sample.GetUINT32(&MFSampleExtension_CleanPoint).unwrap_or(0) != 0;
                let buffer = sample.ConvertToContiguousBuffer().map_err(e("Output"))?;
                let mut data = std::ptr::null_mut();
                let mut len = 0;
                buffer.Lock(&mut data, None, Some(&mut len)).map_err(e("Output"))?;
                let mut bytes = std::slice::from_raw_parts(data, len as usize).to_vec();
                let _ = buffer.Unlock();
                // Decoders need the parameter sets in band before an IDR.
                if key && !has_sps(&bytes) && !self.sequence_header.is_empty() {
                    let mut with = self.sequence_header.clone();
                    with.extend_from_slice(&bytes);
                    bytes = with;
                }
                Ok(Some((bytes, key)))
            }
        }

        /// Events the asynchronous encoder has queued: inputs it wants, and
        /// outputs ready.
        fn pump(&mut self, out: &mut Vec<(Vec<u8>, bool)>) -> Result<()> {
            let Some(events) = self.events.clone() else { return Ok(()) };
            loop {
                let event = match unsafe { events.GetEvent(MF_EVENT_FLAG_NO_WAIT) } {
                    Ok(event) => event,
                    Err(err) if err.code() == MF_E_NO_EVENTS_AVAILABLE => return Ok(()),
                    Err(err) => return Err(format!("Encoder events: {err}")),
                };
                let kind = MF_EVENT_TYPE(unsafe { event.GetType() }.unwrap_or(0) as i32);
                if kind == METransformNeedInput {
                    self.need_input += 1;
                } else if kind == METransformHaveOutput {
                    if let Some(frame) = self.take_output()? {
                        out.push(frame);
                    }
                }
            }
        }

        /// Encodes one frame and returns what the encoder gave back.
        fn encode(&mut self, gpu: &Gpu, texture: &ID3D11Texture2D, time: i64, duration: i64, key: bool) -> Result<Vec<(Vec<u8>, bool)>> {
            let mut out = Vec::new();
            if key {
                if let Some(codec) = &self.codec {
                    unsafe {
                        let _ = codec.SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &variant_u32(1));
                    }
                }
            }
            let sample = self.sample(gpu, texture)?;
            unsafe {
                sample.SetSampleTime(time).map_err(e("Sample"))?;
                sample.SetSampleDuration(duration).map_err(e("Sample"))?;
            }
            if self.events.is_none() {
                unsafe { self.mft.ProcessInput(0, &sample, 0) }.map_err(e("Encoding"))?;
                while let Some(frame) = self.take_output()? {
                    out.push(frame);
                }
                return Ok(out);
            }
            let deadline = Instant::now() + Duration::from_millis(500);
            while self.need_input == 0 {
                self.pump(&mut out)?;
                if self.need_input == 0 {
                    if Instant::now() > deadline {
                        return Err("The encoder stopped asking for frames".into());
                    }
                    thread::sleep(Duration::from_micros(200));
                }
            }
            unsafe { self.mft.ProcessInput(0, &sample, 0) }.map_err(e("Encoding"))?;
            self.need_input -= 1;
            // Low-latency encoders give each frame back before the next
            // goes in; wait for it rather than for the next capture.
            let deadline = Instant::now() + Duration::from_millis(100);
            while out.is_empty() && Instant::now() < deadline {
                self.pump(&mut out)?;
                if out.is_empty() {
                    thread::sleep(Duration::from_micros(200));
                }
            }
            Ok(out)
        }
    }

    impl Drop for Encoder {
        fn drop(&mut self) {
            unsafe {
                let _ = self.mft.ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
                if let Some(events) = &self.events {
                    if let Ok(shutdown) = events.cast::<IMFShutdown>() {
                        let _ = shutdown.Shutdown();
                    }
                }
            }
        }
    }

    pub(super) fn has_sps(annexb: &[u8]) -> bool {
        annexb.windows(4).any(|w| w[0] == 0 && w[1] == 0 && w[2] == 1 && w[3] & 0x1f == 7)
    }

    /// How the stream's size follows from the output's: no wider than
    /// asked, the same shape, even both ways.
    pub(super) fn stream_size((w, h): (u32, u32), max_width: u32) -> (u32, u32) {
        let (w2, h2) = if w > max_width {
            (max_width, (h as u64 * max_width as u64 / w as u64) as u32)
        } else {
            (w, h)
        };
        ((w2 & !1).max(2), (h2 & !1).max(2))
    }

    enum Pipeline {
        Stopped,
        /// The desktop changed (a mode switch, the secure desktop): build
        /// everything again.
        Again,
    }

    pub(super) fn capture_loop(handle: u64, post: Post, config: &Config, capture: &Capture, geometry: &Mutex<Option<Geometry>>) -> Result<()> {
        startup();
        let mut ids = 0u32;
        let mut stats = Stats::new();
        let mut failures = 0;
        loop {
            match pipeline(handle, post, config, capture, geometry, &mut ids, &mut stats) {
                Ok(Pipeline::Stopped) => return Ok(()),
                Ok(Pipeline::Again) => failures = 0,
                Err(error) => {
                    failures += 1;
                    if failures > 20 {
                        return Err(error);
                    }
                    let note = json!({"retrying": error}).to_string();
                    post_to(post, handle, framed(INFO, &[note.as_bytes()]));
                }
            }
            if capture.stop.load(Ordering::Relaxed) {
                return Ok(());
            }
            thread::sleep(Duration::from_millis(250));
            capture.keyframe.store(true, Ordering::Relaxed);
        }
    }

    fn pipeline(handle: u64, post: Post, config: &Config, capture: &Capture, geometry: &Mutex<Option<Geometry>>, ids: &mut u32, stats: &mut Stats) -> Result<Pipeline> {
        let (mut list, desktop) = outputs()?;
        if config.display >= list.len() {
            return Err(format!("There is no display {}", config.display + 1));
        }
        let out = list.swap_remove(config.display);
        if let Ok(mut g) = geometry.lock() {
            *g = Some(Geometry {
                output: (out.rect.left, out.rect.top, out.rect.right, out.rect.bottom),
                desktop: (desktop.left, desktop.top, desktop.right, desktop.bottom),
            });
        }
        let gpu = Gpu::new(&out.adapter)?;
        // Asking for 8-bit BGRA has DXGI convert an HDR or colour-managed
        // (FP16) desktop, which the video processor would refuse.
        let duplication = out
            .output
            .cast::<IDXGIOutput5>()
            .and_then(|o5| unsafe { o5.DuplicateOutput1(&gpu.device, 0, &[DXGI_FORMAT_B8G8R8A8_UNORM]) })
            .or_else(|_| unsafe { out.output.DuplicateOutput(&gpu.device) })
            .map_err(e("Capturing the display"))?;
        let mode = unsafe { duplication.GetDesc() }.ModeDesc;
        let source = (mode.Width, mode.Height);
        let size = stream_size(source, config.width);
        const RING: usize = 4;
        let mut converter = Converter::new(&gpu, source, size, RING)?;
        let mut encoder = if config.software {
            Encoder::software(&gpu, size, config)?
        } else {
            match Encoder::hardware(&gpu, out.luid, size, config) {
                Ok(encoder) => encoder,
                Err(_) => Encoder::software(&gpu, size, config)?,
            }
        };
        let fields = json!({
            "width": size.0, "height": size.1, "sourceWidth": source.0, "sourceHeight": source.1,
            "encoder": encoder.name, "hardware": encoder.hardware, "maxFps": config.fps,
        });
        post_to(post, handle, framed(INFO, &[fields.to_string().as_bytes()]));
        let interval = Duration::from_secs_f64(1.0 / config.fps as f64);
        let duration = (10_000_000 / config.fps) as i64;
        let mut next = Instant::now();
        let mut slot = 0usize;
        let mut last: Option<usize> = None;
        let mut first = true;
        loop {
            if capture.stop.load(Ordering::Relaxed) {
                return Ok(Pipeline::Stopped);
            }
            if let Some(report) = stats.report(fields.clone(), capture.latency_us.load(Ordering::Relaxed)) {
                post_to(post, handle, framed(INFO, &[report.to_string().as_bytes()]));
            }
            // Never more than `inflight` frames on the way: capture waits
            // instead, so a slow link costs frames, not latency.
            let acked = capture.acked.load(Ordering::Relaxed);
            if ids.wrapping_sub(acked) >= config.inflight && *ids != 0 {
                thread::sleep(Duration::from_millis(1));
                continue;
            }
            let now = Instant::now();
            if now < next {
                thread::sleep(next - now);
            }
            next = (next + interval).max(Instant::now());
            let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
            let mut resource = None;
            let acquired = unsafe { duplication.AcquireNextFrame(50, &mut info, &mut resource) };
            let key = capture.keyframe.swap(false, Ordering::Relaxed) || first;
            match acquired {
                Ok(()) => {
                    let texture = resource.and_then(|r| r.cast::<ID3D11Texture2D>().ok());
                    // A pointer move alone changes no pixels.
                    let fresh = info.LastPresentTime != 0 || first;
                    let result = match (&texture, fresh) {
                        (Some(texture), true) => {
                            let next = (slot + 1) % RING;
                            converter.convert(&gpu, texture, next)
                        }
                        _ => Ok(false),
                    };
                    unsafe {
                        let _ = duplication.ReleaseFrame();
                    }
                    let converted = result?;
                    if converted {
                        slot = (slot + 1) % RING;
                        last = Some(slot);
                    }
                    if !converted {
                        if key {
                            capture.keyframe.store(true, Ordering::Relaxed);
                        }
                        stats.skipped += 1;
                        continue;
                    }
                }
                Err(err) if err.code() == DXGI_ERROR_WAIT_TIMEOUT => {
                    // A still screen: nothing to send, unless the viewer
                    // needs a keyframe of it.
                    if !(key && last.is_some()) {
                        if key {
                            capture.keyframe.store(true, Ordering::Relaxed);
                        }
                        continue;
                    }
                }
                Err(err) if err.code() == DXGI_ERROR_ACCESS_LOST => return Ok(Pipeline::Again),
                Err(err) => return Err(format!("Capturing: {err}")),
            }
            let Some(index) = last else { continue };
            first = false;
            let time = stats.began.elapsed().as_nanos() as i64 / 100;
            let captured = Instant::now();
            let frames = encoder.encode(&gpu, &converter.outputs[index].0, time, duration, key)?;
            stats.encode_ms = captured.elapsed().as_secs_f64() * 1000.0;
            for (bytes, is_key) in frames {
                *ids = ids.wrapping_add(1);
                let micros = stats.began.elapsed().as_micros() as u64;
                let flags = if is_key { KEY } else { 0 };
                stats.frames += 1;
                stats.bytes += bytes.len() as u64;
                if let Ok(mut sent) = capture.sent.lock() {
                    sent.push_back((*ids, captured));
                    if sent.len() > 256 {
                        sent.pop_front();
                    }
                }
                post_to(post, handle, framed(VIDEO, &[&ids.to_le_bytes(), &micros.to_le_bytes(), &[flags], &bytes]));
            }
        }
    }

    // ── decoder ──

    /// Hardware decoding: the decoder writes NV12 textures, a video
    /// processor turns them into RGBA on the GPU, and only the picture is
    /// read back.
    struct GpuDecode {
        gpu: Gpu,
        manager: IMFDXGIDeviceManager,
        /// For one picture size: the processor, its RGBA target and the
        /// copy the CPU reads.
        convert: Option<GpuConvert>,
    }

    struct GpuConvert {
        size: (u32, u32),
        enumerator: ID3D11VideoProcessorEnumerator,
        processor: ID3D11VideoProcessor,
        target: ID3D11Texture2D,
        view: ID3D11VideoProcessorOutputView,
        staging: ID3D11Texture2D,
    }

    impl GpuDecode {
        fn new() -> Result<GpuDecode> {
            let factory: IDXGIFactory1 = unsafe { CreateDXGIFactory1() }.map_err(e("DXGI"))?;
            let adapter = unsafe { factory.EnumAdapters1(0) }.map_err(e("Adapter"))?;
            let gpu = Gpu::new(&adapter)?;
            let mut token = 0;
            let mut manager = None;
            unsafe { MFCreateDXGIDeviceManager(&mut token, &mut manager) }.map_err(e("Device manager"))?;
            let manager = manager.ok_or("No device manager")?;
            unsafe { manager.ResetDevice(&gpu.device, token) }.map_err(e("Device manager"))?;
            Ok(GpuDecode { gpu, manager, convert: None })
        }

        fn converter(&mut self, texture: &ID3D11Texture2D, (w, h): (u32, u32)) -> Result<()> {
            if self.convert.as_ref().is_some_and(|c| c.size == (w, h)) {
                return Ok(());
            }
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            unsafe { texture.GetDesc(&mut desc) };
            let content = D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
                InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
                InputFrameRate: DXGI_RATIONAL { Numerator: 60, Denominator: 1 },
                InputWidth: desc.Width,
                InputHeight: desc.Height,
                OutputFrameRate: DXGI_RATIONAL { Numerator: 60, Denominator: 1 },
                OutputWidth: w,
                OutputHeight: h,
                Usage: D3D11_VIDEO_USAGE_OPTIMAL_SPEED,
            };
            let g = &self.gpu;
            let enumerator = unsafe { g.video.CreateVideoProcessorEnumerator(&content) }.map_err(e("Video processor"))?;
            let processor = unsafe { g.video.CreateVideoProcessor(&enumerator, 0) }.map_err(e("Video processor"))?;
            unsafe {
                let vc = &g.video_context;
                // BT.709 studio range in, full-range RGB out.
                vc.VideoProcessorSetStreamColorSpace(&processor, 0, &D3D11_VIDEO_PROCESSOR_COLOR_SPACE { _bitfield: (1 << 2) | (1 << 4) });
                vc.VideoProcessorSetOutputColorSpace(&processor, &D3D11_VIDEO_PROCESSOR_COLOR_SPACE { _bitfield: 0 });
                vc.VideoProcessorSetStreamFrameFormat(&processor, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
                vc.VideoProcessorSetStreamAutoProcessingMode(&processor, 0, false);
                let rect = RECT { left: 0, top: 0, right: w as i32, bottom: h as i32 };
                vc.VideoProcessorSetStreamSourceRect(&processor, 0, true, Some(&rect));
                vc.VideoProcessorSetStreamDestRect(&processor, 0, true, Some(&rect));
                vc.VideoProcessorSetOutputTargetRect(&processor, true, Some(&rect));
            }
            let target = g.texture(w, h, DXGI_FORMAT_R8G8B8A8_UNORM, D3D11_BIND_RENDER_TARGET, D3D11_USAGE_DEFAULT, 0)?;
            let view_desc = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC {
                ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D,
                Anonymous: D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPOV { MipSlice: 0 } },
            };
            let mut view = None;
            unsafe { g.video.CreateVideoProcessorOutputView(&target, &enumerator, &view_desc, Some(&mut view)) }
                .map_err(e("Output view"))?;
            let staging = g.texture(w, h, DXGI_FORMAT_R8G8B8A8_UNORM, D3D11_BIND_FLAG(0), D3D11_USAGE_STAGING, D3D11_CPU_ACCESS_READ.0 as u32)?;
            self.convert = Some(GpuConvert { size: (w, h), enumerator, processor, target, view: view.ok_or("No output view")?, staging });
            Ok(())
        }

        /// RGBA rows of slice [index] of decoded texture [texture] into [out].
        fn read(&mut self, texture: &ID3D11Texture2D, index: u32, size: (u32, u32), out: &mut [u8]) -> Result<()> {
            self.converter(texture, size)?;
            let g = &self.gpu;
            let c = self.convert.as_ref().unwrap();
            let input_desc = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC {
                FourCC: 0,
                ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D,
                Anonymous: D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPIV { MipSlice: 0, ArraySlice: index } },
            };
            let mut input = None;
            unsafe { g.video.CreateVideoProcessorInputView(texture, &c.enumerator, &input_desc, Some(&mut input)) }
                .map_err(e("Input view"))?;
            let mut streams = [D3D11_VIDEO_PROCESSOR_STREAM {
                Enable: true.into(),
                pInputSurface: ManuallyDrop::new(input),
                ..Default::default()
            }];
            let result = unsafe { g.video_context.VideoProcessorBlt(&c.processor, &c.view, 0, &streams) };
            unsafe { ManuallyDrop::drop(&mut streams[0].pInputSurface) };
            result.map_err(e("Convert"))?;
            let (w, h) = (size.0 as usize, size.1 as usize);
            unsafe {
                g.context.CopyResource(&c.staging, &c.target);
                let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
                g.context.Map(&c.staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped)).map_err(e("Reading the picture"))?;
                let src = mapped.pData as *const u8;
                for y in 0..h {
                    std::ptr::copy_nonoverlapping(src.add(y * mapped.RowPitch as usize), out.as_mut_ptr().add(y * w * 4), w * 4);
                }
                g.context.Unmap(&c.staging, 0);
            }
            Ok(())
        }
    }

    struct Decoder {
        mft: IMFTransform,
        gpu: Option<GpuDecode>,
        provides: bool,
        /// The decoded buffer's size (height padded, often to 16) and the
        /// picture's.
        coded: (u32, u32),
        picture: (u32, u32),
        stride: u32,
    }

    impl Decoder {
        /// With [hardware], decoding on the GPU (DXVA) where the decoder can;
        /// otherwise in software.
        fn new(hardware: bool) -> Result<Decoder> {
            let mft: IMFTransform = unsafe { CoCreateInstance(&CLSID_MSH264DecoderMFT, None, CLSCTX_INPROC_SERVER) }
                .map_err(e("H.264 decoder"))?;
            let aware = unsafe { mft.GetAttributes() }
                .ok()
                .and_then(|a| unsafe { a.GetUINT32(&MF_SA_D3D11_AWARE) }.ok())
                .unwrap_or(0)
                != 0;
            let gpu = if hardware && aware {
                GpuDecode::new().ok().filter(|g| {
                    unsafe { mft.ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, g.manager.as_raw() as usize) }.is_ok()
                })
            } else {
                None
            };
            unsafe {
                // Otherwise it holds up to a whole picture buffer back in
                // case frames need reordering, which ours never do.
                if let Ok(attributes) = mft.GetAttributes() {
                    let _ = attributes.SetUINT32(&MF_LOW_LATENCY, 1);
                }
                if let Ok(codec) = mft.cast::<ICodecAPI>() {
                    let _ = codec.SetValue(&CODECAPI_AVLowLatencyMode, &variant_bool(true));
                }
                let input = MFCreateMediaType().map_err(e("Media type"))?;
                input.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video).map_err(e("Input type"))?;
                input.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264).map_err(e("Input type"))?;
                mft.SetInputType(0, &input, 0).map_err(e("Decoder input"))?;
            }
            let mut decoder = Decoder { mft, gpu, provides: false, coded: (0, 0), picture: (0, 0), stride: 0 };
            decoder.choose_output()?;
            unsafe {
                decoder.mft.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0).map_err(e("Decoder"))?;
                decoder.mft.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0).map_err(e("Decoder"))?;
            }
            Ok(decoder)
        }

        fn choose_output(&mut self) -> Result<()> {
            unsafe {
                for i in 0.. {
                    let Ok(t) = self.mft.GetOutputAvailableType(0, i) else { break };
                    if t.GetGUID(&MF_MT_SUBTYPE).ok() != Some(MFVideoFormat_NV12) {
                        continue;
                    }
                    self.mft.SetOutputType(0, &t, 0).map_err(e("Decoder output"))?;
                    let size = t.GetUINT64(&MF_MT_FRAME_SIZE).unwrap_or(0);
                    self.coded = ((size >> 32) as u32, size as u32);
                    self.picture = self.coded;
                    let mut aperture = MFVideoArea::default();
                    let bytes = std::slice::from_raw_parts_mut(&mut aperture as *mut _ as *mut u8, std::mem::size_of::<MFVideoArea>());
                    if t.GetBlob(&MF_MT_MINIMUM_DISPLAY_APERTURE, bytes, None).is_ok() && aperture.Area.cx > 0 {
                        self.picture = (aperture.Area.cx as u32, aperture.Area.cy as u32);
                    }
                    self.stride = t.GetUINT32(&MF_MT_DEFAULT_STRIDE).map(|s| s as i32 as u32).unwrap_or(self.coded.0);
                    self.provides = self
                        .mft
                        .GetOutputStreamInfo(0)
                        .map(|i| i.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 as u32 != 0)
                        .unwrap_or(false);
                    return Ok(());
                }
            }
            Err("The decoder offers no NV12 output".into())
        }

        /// Decodes one access unit; converts each picture out into RGBA.
        fn decode(&mut self, annexb: &[u8], time: i64, view: &View) -> Result<()> {
            unsafe {
                let buffer = MFCreateMemoryBuffer(annexb.len() as u32).map_err(e("Buffer"))?;
                let mut data = std::ptr::null_mut();
                buffer.Lock(&mut data, None, None).map_err(e("Buffer"))?;
                std::ptr::copy_nonoverlapping(annexb.as_ptr(), data, annexb.len());
                let _ = buffer.Unlock();
                buffer.SetCurrentLength(annexb.len() as u32).map_err(e("Buffer"))?;
                let sample = MFCreateSample().map_err(e("Sample"))?;
                sample.AddBuffer(&buffer).map_err(e("Sample"))?;
                sample.SetSampleTime(time).map_err(e("Sample"))?;
                self.mft.ProcessInput(0, &sample, 0).map_err(e("Decoding"))?;
                loop {
                    let sample = if self.provides {
                        None
                    } else {
                        let info = self.mft.GetOutputStreamInfo(0).map_err(e("Decoder"))?;
                        let s = MFCreateSample().map_err(e("Sample"))?;
                        s.AddBuffer(&MFCreateMemoryBuffer(info.cbSize.max(1)).map_err(e("Buffer"))?).map_err(e("Sample"))?;
                        Some(s)
                    };
                    let mut buffers = [MFT_OUTPUT_DATA_BUFFER { dwStreamID: 0, pSample: ManuallyDrop::new(sample), dwStatus: 0, pEvents: ManuallyDrop::new(None) }];
                    let mut status = 0;
                    let result = self.mft.ProcessOutput(0, &mut buffers, &mut status);
                    let sample = ManuallyDrop::take(&mut buffers[0].pSample);
                    drop(ManuallyDrop::take(&mut buffers[0].pEvents));
                    match result {
                        Ok(()) => {}
                        Err(err) if err.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(()),
                        Err(err) if err.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                            self.choose_output()?;
                            continue;
                        }
                        Err(err) => return Err(format!("Decoding: {err}")),
                    }
                    if let Some(sample) = sample {
                        self.picture_out(&sample, view)?;
                    }
                }
            }
        }

        fn picture_out(&mut self, sample: &IMFSample, view: &View) -> Result<()> {
            unsafe {
                let (w, h) = (self.picture.0 as usize, self.picture.1 as usize);
                let mut picture = view.spare();
                picture.rgba.resize(w * h * 4, 0);
                picture.width = w as u32;
                picture.height = h as u32;
                if let Some(gpu) = self.gpu.as_mut() {
                    let first = sample.GetBufferByIndex(0).map_err(e("Picture"))?;
                    let dxgi = first.cast::<IMFDXGIBuffer>().map_err(e("Picture"))?;
                    let mut raw = std::ptr::null_mut();
                    dxgi.GetResource(&ID3D11Texture2D::IID, &mut raw).map_err(e("Picture"))?;
                    let texture = ID3D11Texture2D::from_raw(raw);
                    let index = dxgi.GetSubresourceIndex().unwrap_or(0);
                    gpu.read(&texture, index, (w as u32, h as u32), &mut picture.rgba)?;
                    view.publish(picture);
                    return Ok(());
                }
                let buffer = sample.ConvertToContiguousBuffer().map_err(e("Picture"))?;
                if let Ok(b2) = buffer.cast::<IMF2DBuffer>() {
                    let mut scan = std::ptr::null_mut();
                    let mut pitch = 0;
                    b2.Lock2D(&mut scan, &mut pitch).map_err(e("Picture"))?;
                    let pitch = pitch.unsigned_abs() as usize;
                    let rows = self.coded.1 as usize;
                    let y = std::slice::from_raw_parts(scan, pitch * rows);
                    let uv = std::slice::from_raw_parts(scan.add(pitch * rows), pitch * rows / 2);
                    nv12_to_rgba(y, uv, pitch, w, h.min(rows), &mut picture.rgba);
                    let _ = b2.Unlock2D();
                } else {
                    let mut data = std::ptr::null_mut();
                    let mut len = 0;
                    buffer.Lock(&mut data, None, Some(&mut len)).map_err(e("Picture"))?;
                    let pitch = (self.stride as usize).max(w);
                    let rows = self.coded.1 as usize;
                    if (len as usize) < pitch * rows * 3 / 2 {
                        let _ = buffer.Unlock();
                        return Err("A decoded picture was short".into());
                    }
                    let all = std::slice::from_raw_parts(data, len as usize);
                    nv12_to_rgba(&all[..pitch * rows], &all[pitch * rows..], pitch, w, h.min(rows), &mut picture.rgba);
                    let _ = buffer.Unlock();
                }
                view.publish(picture);
                Ok(())
            }
        }
    }

    pub(super) fn decode_loop(view: Arc<View>, frames: Receiver<Vec<u8>>) {
        startup();
        let mut decoder: Option<Decoder> = None;
        let mut waiting_for_key = true;
        // On the GPU until that fails once; then in software for this view.
        let mut hardware = true;
        while let Ok(frame) = frames.recv() {
            view.queued.fetch_sub(1, Ordering::Relaxed);
            // `[u32 id][u64 µs][u8 flags][Annex B]`
            if frame.len() < 13 {
                continue;
            }
            let micros = u64::from_le_bytes(frame[4..12].try_into().unwrap());
            let key = frame[12] & KEY != 0;
            if waiting_for_key && !key {
                view.wants_key.store(true, Ordering::Relaxed);
                continue;
            }
            waiting_for_key = false;
            if decoder.is_none() {
                match Decoder::new(hardware) {
                    Ok(d) => decoder = Some(d),
                    Err(error) => {
                        view.fail(error);
                        waiting_for_key = true;
                        continue;
                    }
                }
            }
            let began = Instant::now();
            if let Err(error) = decoder.as_mut().unwrap().decode(&frame[13..], micros as i64 * 10, &view) {
                if decoder.as_ref().is_some_and(|d| d.gpu.is_some()) {
                    hardware = false;
                }
                view.fail(error);
                decoder = None;
                waiting_for_key = true;
                continue;
            }
            view.decode_us.store(began.elapsed().as_micros() as u64, Ordering::Relaxed);
        }
    }
}

// ─────────────────────────────── C API ───────────────────────────────

unsafe fn bytes<'a>(data: *const u8, len: usize) -> &'a [u8] {
    if len == 0 || data.is_null() {
        &[]
    } else {
        std::slice::from_raw_parts(data, len)
    }
}

/// 1 where this build can capture and view.
#[no_mangle]
pub extern "C" fn ournet_desktop_available() -> i32 {
    cfg!(windows) as i32
}

/// Starts capturing with JSON [config] (see [Config]). Frames, figures and
/// errors are posted to [post] already framed for the wire; an empty
/// message means the capture ended. Returns its handle, or 0.
#[no_mangle]
pub unsafe extern "C" fn ournet_desktop_capture_start(post: Post, config: *const u8, len: usize) -> u64 {
    let config = bytes(config, len).to_vec();
    catch_unwind(move || {
        let Ok(config) = serde_json::from_slice::<Config>(&config) else {
            return 0;
        };
        let config = config.bounded();
        let handle = NEXT.fetch_add(1, Ordering::Relaxed);
        let (input, states) = mpsc::channel();
        let capture = Arc::new(Capture {
            stop: AtomicBool::new(false),
            acked: AtomicU32::new(0),
            keyframe: AtomicBool::new(true),
            input: Mutex::new(Some(input)),
            sent: Mutex::new(VecDeque::new()),
            latency_us: AtomicU64::new(0),
        });
        let geometry = Arc::new(Mutex::new(None));
        if let Ok(mut c) = CAPTURES.lock() {
            c.get_or_insert_with(HashMap::new).insert(handle, capture.clone());
        }
        let (c, g) = (capture.clone(), geometry.clone());
        let input_thread = thread::Builder::new()
            .name("ournet-desktop-input".into())
            .spawn(move || {
                let _ = catch_unwind(AssertUnwindSafe(|| run_input(c, states, g)));
            });
        let started = thread::Builder::new().name("ournet-desktop-capture".into()).spawn(move || {
            let c = capture.clone();
            let result = catch_unwind(AssertUnwindSafe(|| run_capture(handle, post, config, capture, geometry)));
            if result.is_err() {
                c.stop.store(true, Ordering::Relaxed);
                post_to(post, handle, Vec::new());
            }
            if let Ok(mut all) = CAPTURES.lock() {
                all.as_mut().map(|m| m.remove(&handle));
            }
        });
        if started.is_err() || input_thread.is_err() {
            return 0;
        }
        handle
    })
    .unwrap_or(0)
}

/// A datagram from the viewer: input state, an ack or a keyframe request.
#[no_mangle]
pub unsafe extern "C" fn ournet_desktop_capture_datagram(handle: u64, data: *const u8, len: usize) -> i32 {
    let data = bytes(data, len);
    let Some(capture) = capture(handle) else { return 0 };
    match data.first() {
        Some(&INPUT) => match InputState::parse(data) {
            Some(state) => capture
                .input
                .lock()
                .ok()
                .and_then(|i| i.as_ref().map(|i| i.send(state).is_ok()))
                .unwrap_or(false) as i32,
            None => 0,
        },
        Some(&ACK) if data.len() == 5 => {
            capture.acked(u32::from_le_bytes(data[1..5].try_into().unwrap()));
            1
        }
        Some(&KEYFRAME) => {
            capture.keyframe.store(true, Ordering::Relaxed);
            1
        }
        _ => 0,
    }
}

/// Stops a capture; it posts its end (an empty message) once stopped, and
/// everything held is released.
#[no_mangle]
pub extern "C" fn ournet_desktop_capture_stop(handle: u64) -> i32 {
    let Some(capture) = capture(handle) else { return 0 };
    capture.stop.store(true, Ordering::Relaxed);
    if let Ok(mut i) = capture.input.lock() {
        i.take();
    }
    1
}

/// Opens a view: a decoder on a thread of its own. Returns its handle.
#[no_mangle]
pub extern "C" fn ournet_desktop_view_open() -> u64 {
    catch_unwind(|| {
        let handle = NEXT.fetch_add(1, Ordering::Relaxed);
        let (frames, queue) = mpsc::sync_channel(VIEW_QUEUE);
        let view = Arc::new(View {
            frames: Mutex::new(Some(frames)),
            queued: AtomicU32::new(0),
            buffers: Mutex::new(Buffers::default()),
            notify: Mutex::new(None),
            decoded: AtomicU64::new(0),
            size: AtomicU64::new(0),
            wants_key: AtomicBool::new(false),
            decode_us: AtomicU64::new(0),
            error: Mutex::new(String::new()),
        });
        let v = view.clone();
        if thread::Builder::new()
            .name("ournet-desktop-view".into())
            .spawn(move || {
                let _ = catch_unwind(AssertUnwindSafe(|| run_view(v, queue)));
            })
            .is_err()
        {
            return 0;
        }
        if let Ok(mut views) = VIEWS.lock() {
            views.get_or_insert_with(HashMap::new).insert(handle, view);
        }
        handle
    })
    .unwrap_or(0)
}

/// Queues one video frame's body for decoding. 0 when the decoder has
/// fallen behind: the frame was dropped and a keyframe is wanted.
#[no_mangle]
pub unsafe extern "C" fn ournet_desktop_view_push(handle: u64, data: *const u8, len: usize) -> i32 {
    let Some(view) = view(handle) else { return 0 };
    let frame = bytes(data, len).to_vec();
    let sent = view.frames.lock().ok().and_then(|f| f.as_ref().map(|f| f.try_send(frame).is_ok())).unwrap_or(false);
    if sent {
        view.queued.fetch_add(1, Ordering::Relaxed);
    } else {
        view.wants_key.store(true, Ordering::Relaxed);
    }
    sent as i32
}

/// Sets (or, with a null [notify], clears) what is called on the decoder's
/// thread when a picture is ready. Clearing waits for a call in progress.
#[no_mangle]
pub extern "C" fn ournet_desktop_view_bind(handle: u64, notify: Option<Notify>, context: *mut c_void) -> i32 {
    let Some(view) = view(handle) else { return 0 };
    if let Ok(mut n) = view.notify.lock() {
        *n = notify.map(|f| (f, context as usize));
    }
    1
}

/// The newest picture, for the texture to copy: RGBA rows of `*width` ×
/// `*height`, valid until the next call. Null before the first. Called from
/// one thread at a time (Flutter's raster thread).
#[no_mangle]
pub unsafe extern "C" fn ournet_desktop_view_lock(handle: u64, width: *mut u32, height: *mut u32) -> *const u8 {
    let Some(view) = view(handle) else { return std::ptr::null() };
    let Ok(mut b) = view.buffers.lock() else { return std::ptr::null() };
    if let Some(ready) = b.ready.take() {
        let old = std::mem::replace(&mut b.front, ready);
        if !old.rgba.is_empty() {
            b.spare = Some(old);
        }
    }
    if b.front.rgba.is_empty() {
        return std::ptr::null();
    }
    if !width.is_null() {
        *width = b.front.width;
    }
    if !height.is_null() {
        *height = b.front.height;
    }
    // The vector stays put until the next lock replaces it.
    b.front.rgba.as_ptr()
}

/// `[pictures decoded, width, height, decode µs, wants a keyframe (taken)]`.
#[no_mangle]
pub unsafe extern "C" fn ournet_desktop_view_status(handle: u64, out: *mut u64) -> i32 {
    let Some(view) = view(handle) else { return 0 };
    if out.is_null() {
        return 0;
    }
    let size = view.size.load(Ordering::Relaxed);
    let values = [
        view.decoded.load(Ordering::Relaxed),
        size >> 32,
        size & 0xffff_ffff,
        view.decode_us.load(Ordering::Relaxed),
        view.wants_key.swap(false, Ordering::Relaxed) as u64,
    ];
    std::ptr::copy_nonoverlapping(values.as_ptr(), out, values.len());
    1
}

/// The decoder's last error, as UTF-8 into [out] (at most [cap] bytes);
/// returns its length.
#[no_mangle]
pub unsafe extern "C" fn ournet_desktop_view_error(handle: u64, out: *mut u8, cap: usize) -> usize {
    let Some(view) = view(handle) else { return 0 };
    let Ok(error) = view.error.lock() else { return 0 };
    let n = error.len().min(cap);
    if !out.is_null() {
        std::ptr::copy_nonoverlapping(error.as_ptr(), out, n);
    }
    n
}

/// Closes a view: its decoder finishes the frame in hand and exits.
#[no_mangle]
pub extern "C" fn ournet_desktop_view_close(handle: u64) -> i32 {
    let removed = VIEWS.lock().ok().and_then(|mut v| v.as_mut()?.remove(&handle));
    match removed {
        Some(view) => {
            if let Ok(mut n) = view.notify.lock() {
                n.take();
            }
            if let Ok(mut f) = view.frames.lock() {
                f.take();
            }
            1
        }
        None => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn input_state_round_trips_and_refuses_malformed() {
        let state = InputState { seq: 7, x: 100, y: 65535, buttons: 5, wheel: -240, hwheel: 120, keys: vec![0x04, 0xe1] };
        let bytes = state.encode();
        assert_eq!(InputState::parse(&bytes), Some(state));
        assert_eq!(InputState::parse(&bytes[..bytes.len() - 1]), None);
        let mut many = InputState::default();
        many.keys = vec![0x04; 17];
        assert_eq!(InputState::parse(&many.encode()), None);
        assert_eq!(InputState::parse(&[ACK, 0, 0, 0, 0]), None);
    }

    #[test]
    fn applying_states_injects_only_differences_and_never_sticks() {
        let mut applied = Applied::default();
        let s = |seq, x, buttons, wheel, keys: &[u16]| InputState { seq, x, y: 0, buttons, wheel, hwheel: 0, keys: keys.to_vec() };
        // The first state sets the wheel without scrolling.
        assert_eq!(applied.apply(s(1, 10, 0, 480, &[])), vec![Action::Move(10, 0)]);
        assert_eq!(
            applied.apply(s(2, 10, 1, 600, &[0x04])),
            vec![Action::Key(0x1e, true), Action::Button(1, true), Action::Wheel(120)]
        );
        // Old and repeated states change nothing.
        assert!(applied.apply(s(2, 99, 0, 0, &[])).is_empty());
        assert!(applied.apply(s(1, 99, 0, 0, &[])).is_empty());
        assert!(applied.holding());
        assert_eq!(applied.release(), vec![Action::Key(0x1e, false), Action::Button(1, false)]);
        assert!(!applied.holding());
        // A lost release arrives as the next state's difference.
        assert_eq!(applied.apply(s(5, 10, 0, 600, &[0x52])), vec![Action::Key(0xe048, true)]);
        // Sequence numbers wrap.
        let mut wrap = Applied::default();
        wrap.apply(s(u32::MAX, 0, 0, 0, &[]));
        assert_eq!(wrap.apply(s(0, 1, 0, 0, &[])), vec![Action::Move(1, 0)]);
    }

    #[test]
    fn scan_codes_cover_the_keyboard() {
        assert_eq!(scan_code(0x04), Some(0x1e)); // A
        assert_eq!(scan_code(0x1d), Some(0x2c)); // Z
        assert_eq!(scan_code(0x27), Some(0x0b)); // 0
        assert_eq!(scan_code(0x29), Some(0x01)); // Escape
        assert_eq!(scan_code(0x45), Some(0x58)); // F12
        assert_eq!(scan_code(0x50), Some(0xe04b)); // Left
        assert_eq!(scan_code(0xe0), Some(0x1d)); // Left Ctrl
        assert_eq!(scan_code(0xe7), Some(0xe05c)); // Right Windows
        assert_eq!(scan_code(0x1a), Some(0x11)); // W
        assert_eq!(scan_code(0x16), Some(0x1f)); // S
        assert_eq!(scan_code(0x02), None);
    }

    #[test]
    fn pointer_maps_onto_the_virtual_desktop() {
        // A second display to the right of a 1920-wide primary.
        let g = Geometry { output: (1920, 0, 3840, 1080), desktop: (0, 0, 3840, 1080) };
        assert_eq!(g.absolute(0, 0).0, 1920 * 65535 / 3839);
        assert_eq!(g.absolute(65535, 65535), (65535, 65535));
        let single = Geometry { output: (0, 0, 1920, 1080), desktop: (0, 0, 1920, 1080) };
        assert_eq!(single.absolute(0, 0), (0, 0));
        assert_eq!(single.absolute(65535, 65535), (65535, 65535));
    }

    #[test]
    fn nv12_converts_grey_and_colour() {
        let (w, h) = (4, 2);
        let y = [16u8, 235, 126, 126, 16, 235, 126, 126];
        let uv = [128u8, 128, 128, 128];
        let mut out = vec![0; w * h * 4];
        nv12_to_rgba(&y, &uv, w, w, h, &mut out);
        assert_eq!(&out[0..4], &[0, 0, 0, 255]);
        assert_eq!(&out[4..8], &[255, 255, 255, 255]);
        assert!((out[8] as i32 - 128).abs() <= 1);
        // Strong red in BT.709 studio range: Y 63, Cb 102, Cr 240.
        let mut red = vec![0; 2 * 2 * 4];
        nv12_to_rgba(&[63, 63, 63, 63], &[102, 240], 2, 2, 2, &mut red);
        assert!(red[0] > 250 && red[1] < 10 && red[2] < 10, "{:?}", &red[0..4]);
    }

    #[test]
    fn large_frames_convert_the_same_split_across_threads() {
        let (w, h) = (1280, 820);
        let y: Vec<u8> = (0..w * h).map(|i| (i * 7 % 220 + 16) as u8).collect();
        let uv: Vec<u8> = (0..w * h / 2).map(|i| (i * 13 % 224 + 16) as u8).collect();
        let mut split = vec![0; w * h * 4];
        nv12_to_rgba(&y, &uv, w, w, h, &mut split);
        let mut whole = vec![0; w * h * 4];
        for row in 0..h {
            let mut line = vec![0; w * 4];
            nv12_to_rgba(&y[row * w..], &uv[(row / 2) * w..], w, w, 1, &mut line);
            whole[row * w * 4..(row + 1) * w * 4].copy_from_slice(&line);
        }
        assert!(split == whole);
    }

    /// How long converting a 1080p picture takes here (release builds).
    #[test]
    #[ignore]
    fn nv12_conversion_speed() {
        let (w, h) = (1920, 1080);
        let (y, uv) = (vec![120u8; w * h], vec![128u8; w * h / 2]);
        let mut out = vec![0; w * h * 4];
        let began = Instant::now();
        for _ in 0..50 {
            nv12_to_rgba(&y, &uv, w, w, h, &mut out);
        }
        eprintln!("1080p NV12 to RGBA: {:?} each", began.elapsed() / 50);
    }

    #[cfg(windows)]
    #[test]
    fn stream_sizes_are_even_and_bounded() {
        assert_eq!(win::stream_size((3840, 2160), 1920), (1920, 1080));
        assert_eq!(win::stream_size((1366, 768), 1920), (1366, 768));
        assert_eq!(win::stream_size((1921, 1081), 4000), (1920, 1080));
        assert_eq!(win::stream_size((2560, 1080), 1280), (1280, 540));
    }

    #[cfg(windows)]
    #[test]
    fn sps_is_found_in_annex_b() {
        assert!(win::has_sps(&[0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68]));
        assert!(!win::has_sps(&[0, 0, 0, 1, 0x65, 1, 2]));
    }

    /// Captures this machine's screen, encodes it, decodes it and checks a
    /// picture comes out, timing each part. Needs an interactive desktop
    /// with a GPU: run with `--ignored` on a Windows machine.
    #[cfg(windows)]
    #[test]
    #[ignore]
    fn capture_encode_decode_round_trip() {
        round_trip(false);
    }

    #[cfg(windows)]
    #[test]
    #[ignore]
    fn software_encoder_round_trip() {
        round_trip(true);
    }

    #[cfg(windows)]
    fn round_trip(software: bool) {
        use std::sync::mpsc::Sender as Tx;
        static SINK: Mutex<Option<Tx<Vec<u8>>>> = Mutex::new(None);
        unsafe extern "C" fn sink(_: u64, data: *mut u8, len: usize) {
            let bytes = if len == 0 { Vec::new() } else { Box::from_raw(std::slice::from_raw_parts_mut(data, len)).into_vec() };
            if let Some(tx) = SINK.lock().unwrap().as_ref() {
                let _ = tx.send(bytes);
            }
        }
        let (tx, rx) = mpsc::channel();
        *SINK.lock().unwrap() = Some(tx);
        let config = format!(r#"{{"fps":60,"kbps":15000,"width":1920,"software":{software}}}"#);
        let handle = unsafe { ournet_desktop_capture_start(sink, config.as_ptr(), config.len()) };
        assert_ne!(handle, 0);
        let view = ournet_desktop_view_open();
        let began = Instant::now();
        let mut video = 0;
        let mut info = Value::Null;
        let mut poked = Instant::now();
        while began.elapsed() < Duration::from_secs(4) {
            // A still screen sends nothing: ask for its picture again.
            if poked.elapsed() > Duration::from_millis(30) {
                unsafe { ournet_desktop_capture_datagram(handle, [KEYFRAME].as_ptr(), 1) };
                poked = Instant::now();
            }
            let Ok(message) = rx.recv_timeout(Duration::from_millis(30)) else { continue };
            if message.is_empty() {
                break;
            }
            let body = &message[5..];
            match message[0] {
                VIDEO => {
                    video += 1;
                    let id = u32::from_le_bytes(body[0..4].try_into().unwrap());
                    unsafe {
                        ournet_desktop_view_push(view, body.as_ptr(), body.len());
                        ournet_desktop_capture_datagram(handle, [ACK, id as u8, (id >> 8) as u8, (id >> 16) as u8, (id >> 24) as u8].as_ptr(), 5);
                    }
                }
                INFO => {
                    info = serde_json::from_slice(body).unwrap();
                    eprintln!("{info}");
                }
                ERROR => panic!("{}", String::from_utf8_lossy(body)),
                _ => {}
            }
        }
        ournet_desktop_capture_stop(handle);
        thread::sleep(Duration::from_millis(1500));
        let mut status = [0u64; 5];
        unsafe { ournet_desktop_view_status(view, status.as_mut_ptr()) };
        let mut error = [0u8; 512];
        let n = unsafe { ournet_desktop_view_error(view, error.as_mut_ptr(), error.len()) };
        eprintln!("info {info}\nvideo frames {video}, decoded {status:?}, error {:?}", String::from_utf8_lossy(&error[..n]));
        assert!(video > 0, "no frames captured");
        assert!(status[0] > 0, "nothing decoded");
        assert_eq!((status[1], status[2]), (info["width"].as_u64().unwrap(), info["height"].as_u64().unwrap()));
        let (mut w, mut h) = (0, 0);
        let picture = unsafe { ournet_desktop_view_lock(view, &mut w, &mut h) };
        assert!(!picture.is_null());
        ournet_desktop_view_close(view);
    }
}
