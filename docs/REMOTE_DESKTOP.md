# Remote Desktop

Status: Windows MVP (October 2026). A plugin, `remote-desktop`, shows one of
your own Windows devices' screens and sends mouse and keyboard back, aiming
at Parsec-style latency: hardware H.264, nothing buffered, input applied as
state rather than as a queue of events.

## Shape

The plugin decides *whether*; the host does the work. Video at 20–50 Mbit/s
never enters WebAssembly or a JSON message, as PLUGINS.md requires of bulk
paths ("configured by plugins, not carried through them").

```
 receiving device (Windows)                      viewing device
 ───────────────────────────                     ─────────────────────────────
 remote-desktop plugin ── admit(device) ◄─ live ── remote-desktop plugin
   (switch on? own device? host checks)            view(device) ─┐
                                                                 ▼
 PeerNetwork `desktop` request ◄──────── QUIC connection ─── RemoteDesktop.open
   │ admitted in the last 15 s?                                  │
   ▼                                                             │
 native capture thread                   reply stream:           ▼
   DXGI Desktop Duplication ──► GPU     [type][len][frame] ─► native decoder
   video processor BGRA→NV12 (+scale)   ───────────────────►   MF H.264 → BGRA
   MF H.264 encoder (NVENC/QSV/AMF,                            double buffer
     software MFT as fallback)                                   │
   ▲                                    datagrams:               ▼
   │ SendInput                    ◄──── input state, acks,   Flutter texture
   └ native input thread                keyframe requests    (DesktopView widget)
```

### Capture and encode (`native/rust/src/desktop.rs`)

- **Capture**: DXGI Desktop Duplication of one output, on the adapter that
  owns it. Frames arrive only when the screen changes, so a still screen
  costs nothing. The cursor is not composited; the viewer's own pointer is
  drawn over the picture in absolute mode.
- **Convert and scale**: `ID3D11VideoProcessor` turns the BGRA desktop into
  NV12 at the stream size on the GPU (no CPU copy on the hardware path).
- **Encode**: the hardware H.264 MFT for that adapter (`MFTEnum2` by LUID),
  asynchronous, low-latency mode, CBR, no B-frames, an infinite GOP with a
  keyframe on request. Without one (a VM, a remote session), the software
  MFT with an NV12 copy read back from the GPU.
- **Pacing**: at most N frames sent and not acknowledged (2 by default).
  When the link cannot keep up the capture loop skips *before* encoding, so
  every frame sent is decodable and latency never queues up.

### Transport (`transport/lib/src/network.dart`)

A dedicated QUIC connection per session, on the existing ALPN, between
admitted devices only:

- Request `{type: "desktop", plugin, fps, kbps, width}` on a bi stream. The
  served side refuses it unless the plugin admitted that device in the last
  15 seconds (below). Older builds answer "Unknown request".
- Server → viewer: the reply stream carries a header line, then frames
  `[u8 type][u32 length][body]`: `1` video (`[u32 id][u64 µs][u8 flags]
  [Annex B]`), `2` info (JSON: size, encoder, fps, kbit/s, latency), `3`
  error. QUIC orders and retransmits; pacing keeps it shallow.
- Viewer → server: QUIC datagrams on the same connection. `1` input state,
  `2` ack (newest frame received), `3` keyframe request.

### Input

Input is **state, not events**: each datagram carries the pointer's
absolute position (0–65535 of the captured output), the held mouse buttons,
running wheel totals and the held keys (USB HID usages). The receiver
applies only the difference from what it last applied and ignores older
sequence numbers, so a lost or repeated datagram never sticks a key or
double-scrolls. The viewer resends the state every 100 ms while anything is
held; the receiver releases everything after 1 s without one, and when the
session ends. Keys are injected as scan codes (games read those).

### Viewing (`app/windows/runner/desktop_texture.cpp`, `DesktopView`)

The decoder (Media Foundation's H.264 MFT, low-latency mode, on the GPU
through DXVA where it can, in software otherwise) runs on its own thread,
converts NV12 to RGBA (on the GPU, or on the CPU after software decoding)
into a triple buffer, and tells the runner a frame is ready; Flutter's texture registry copies it on the raster thread.
Nothing per frame touches the UI isolate except the stream reads. The
`DesktopView` widget (plugin UI library) shows the texture letterboxed,
maps the pointer to the remote output, captures keys while focused and
shows the stream's figures.

### Viewing on Android (`DesktopDecoder.kt`)

Android views (it does not serve): each frame goes over a method channel to
a hardware `MediaCodec` H.264 decoder in low-latency mode, which renders
straight into a Flutter `SurfaceProducer` texture; nothing is read back.
Touch works as the mouse: a finger down is the left button held, so a tap
clicks and a drag drags. There is no keyboard on Android yet.

## Permission

The same as Remote Input: **own devices only**, and receiving starts off.

1. The receiver's plugin has **Allow remote desktop on this device**
   switched on (kept in its storage; off by default).
2. The viewer's plugin sends a live `start` request; the receiver's plugin
   calls `remote-desktop.admit(device)`. The native host refuses that call
   for a device not certified to this identity (`OWN_DEVICE_ONLY`), whatever
   the plugin decides.
3. Dart then accepts one `desktop` connection from that device within 15 s.
4. While streaming, the receiver shows the **Being controlled by …** banner
   (capability `remote-desktop`), and **Stop** ends the stream.

The new grant is `remote-desktop` (API 0.6). Friends' access is not part of
this MVP: it would need a per-friend allow list in the plugin and a host
rule that trusts it, and is the natural next step.

## Using it

Install **Remote Desktop** from Settings › Plugins on both devices. On the
one to be viewed, switch on **Allow remote desktop**. On the other, choose
that device and a quality (720p, 1080p, 1440p or native, each at 60 fps)
and press **Connect**. Click the picture to send mouse and keyboard;
Ctrl+Alt+Shift+F toggles the full view. **Preview this screen** runs this
device's own screen through the same capture, encoder and decoder without
the network or control: a quick check that it works on a machine.

## Measured (25 October 2026, laptop with an RTX 4090, 2560×1600 desktop)

Debug-profile native code (`native-dev`), streaming at 1920×1200:

- Capture, GPU conversion and NVENC encoding: 3–5 ms a frame.
- Capture to the viewer's acknowledgement between two nodes on this
  machine over QUIC: 3–5 ms.
- The software MFT encoder (forced) takes 7–10 ms a frame.
- Decoding on the GPU (DXVA), converting to RGBA there and reading the
  picture back: 2.6 ms a frame at 1280×800 in the app, 7 ms for a 1920×1200
  keyframe. The software decoder it falls back to took 18–23 ms.
- The in-app preview (integration_test/remote_desktop_test.dart) draws the
  picture through the runner's texture.

Not measured: two physical machines over a real network, and games.

## Not yet

In rough order of value:

- Relative mouse (pointer lock) for first-person games; Flutter desktop has
  no pointer lock, so it needs a runner hook.
- Zero-copy viewing: hand the decoded RGBA texture to Flutter as a shared
  `GpuSurfaceTexture` instead of reading it back into a pixel buffer that
  Flutter uploads again.
- Key repeat while a key is held (injected keys do not repeat by
  themselves).
- Audio (WASAPI loopback → Opus), the remote cursor's shape, several
  monitors, clipboard.
- Datagrams with FEC instead of a reliable stream, and bitrate adapting to
  loss and RTT rather than only skipping frames.
- Moving the stream pump off the UI isolate (or into one native iroh, phase
  4 of PLUGINS.md).
- Receivers on other platforms; a keyboard and right-click on Android.
- Friends' access with a per-friend allow list.
