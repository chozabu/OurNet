# Remote Desktop

Status: Windows serves and views, Android views (October 2026). A plugin,
`remote-desktop`, shows a Windows device's screen and sends mouse and
keyboard back, aiming at Parsec-style latency: hardware H.264, nothing
buffered, input applied as state rather than as a queue of events. Sound,
pointer lock for games, the remote pointer's shape, several displays,
clipboard text and bit rate that follows the link come with it (plugin
0.2.0). Your own devices connect; a friend can ask, and the person at the
device decides each time.

## Shape

The plugin decides *whether*; the host does the work. Video at 20–50 Mbit/s
never enters WebAssembly or a JSON message, as PLUGINS.md requires of bulk
paths ("configured by plugins, not carried through them").

```
 receiving device (Windows)                      viewing device
 ───────────────────────────                     ─────────────────────────────
 remote-desktop plugin ── admit() ◄──── live ──── remote-desktop plugin
   (switch on? own device, or a friend         view(device) ─┐
    the person allows now)                                   ▼
 PeerNetwork `desktop` request ◄──────── QUIC connection ─── RemoteDesktops.open
   │ admitted in the last 15 s?                                  │
   ▼                                                             │
 native capture thread                   reply stream:           ▼
   DXGI Desktop Duplication ──► GPU     [type][len][frame] ─► decoder
   video processor BGRA→NV12 (+scale)   video, info, pointer,   Windows: MF H.264
   MF H.264 encoder (NVENC/QSV/AMF,     clipboard, sound          (DXVA) → RGBA
     software MFT as fallback)                                  Android: MediaCodec
 sound thread: WASAPI loopback → PCM                                 │
   ▲                                    datagrams: input         ▼
   │ SendInput                    ◄──── state, acks, keyframe  Flutter texture
   └ native input thread                requests; a control    (DesktopView)
                                        stream: text, keys,
                                        clipboard, display
```

### Capture and encode (`native/rust/src/desktop.rs`)

- **Capture**: DXGI Desktop Duplication of one output, on the adapter that
  owns it, asking for 8-bit BGRA (DXGI converts an HDR or colour-managed
  desktop). Frames arrive only when the screen changes, so a still screen
  costs nothing. The pointer is not drawn into the picture: its shape and
  position travel separately (below).
- **Convert and scale**: `ID3D11VideoProcessor` turns the BGRA desktop into
  NV12 at the stream size on the GPU (no CPU copy on the hardware path).
- **Encode**: the hardware H.264 MFT for that adapter (`MFTEnum2` by LUID),
  asynchronous, low-latency mode, CBR, no B-frames, a long GOP with a
  keyframe on request. Without one (a VM, a remote session), the software
  MFT with an NV12 copy read back from the GPU.
- **Pacing**: at most N frames sent and not acknowledged (2 by default).
  When the link cannot keep up the capture loop skips *before* encoding, so
  every frame sent is decodable and latency never queues up.
- **Bit rate follows the link** (`adapt`): once a second, a link that held
  capture back for a tenth of the second, or whose acknowledgements take
  twice as long as when idle, loses a quarter of the bit rate; one that
  kept up gains a tenth, back towards what was asked. The encoder takes the
  change mid-stream, so nothing restarts.
- **Displays**: every attached output is listed in the stream's figures; the
  viewer picks one and the pipeline is rebuilt on it.
- **Sound** (`desktop_audio.rs`): WASAPI loopback of the default output,
  sent as 10 ms of 16-bit PCM (1.5 Mbit/s at 48 kHz stereo, small beside the
  video and with no codec delay). Silence sends nothing.
- **Clipboard** (`desktop_os.rs`): between a person's own devices only,
  text follows both ways as it changes, and text one side sent is not sent
  back.

### Transport (`transport/lib/src/network.dart`)

A dedicated QUIC connection per session, on the existing ALPN, between
admitted devices only:

- Request `{type: "desktop", plugin, fps, kbps, width, audio, clipboard}`
  on a bi stream. The served side refuses it unless the plugin admitted
  that device in the last 15 seconds (below). Older builds answer "Unknown
  request".
- Server → viewer: the reply stream carries a header line, then frames
  `[u8 type][u32 length][body]`: `1` video (`[u32 id][u64 µs][u8 flags]
  [Annex B]`), `2` info (JSON: size, encoder, fps, kbit/s, latency,
  displays, target bit rate), `3` error, `4` pointer shape (`[u16 w][u16 h]
  [i16 hot x][i16 hot y][RGBA]`), `5` pointer position (`[i32 x][i32 y]
  [u8 visible]`), `6` clipboard text, `7` sound (`[u32 rate][u8 channels]
  [i16…]`). QUIC orders and retransmits; pacing keeps it shallow.
- Viewer → server, as QUIC datagrams on the same connection: `4` input
  state (`1`, the first version without relative movement, is still
  read), `2` ack (newest frame received), `3` keyframe request.
- Viewer → server, reliably: a uni stream the viewer opens with its first
  control message, `[type][u32 length][body]`: `1` typed text, `2`
  clipboard text, `3` display, `4` a key tap.

### Input

Input is **state, not events**: each datagram carries the pointer's
absolute position (0–65535 of the captured output), the held mouse buttons,
running totals of wheel movement and of relative movement (pointer lock),
the held keys (USB HID usages) and a running count of key repeats. The
receiver applies only the difference from what it last applied and ignores
older sequence numbers, so a lost or repeated datagram never sticks a key,
double-scrolls or loses movement. The viewer resends the state every 100 ms
while anything is held; the receiver releases everything after 1 s without
one, and when the session ends. Keys are injected as scan codes (games read
those); a held key repeats as often as the viewer's keyboard repeats it.
Text from a phone's keyboard goes as Unicode keystrokes on the control
stream, so nothing is lost or reordered.

**Pointer lock** (`app/windows/runner/pointer_lock.cpp`): Ctrl+Alt+Shift+L
or the mouse button in the view's toolbar holds the cursor still in the
window, reads the mouse's raw movement and sends it as relative counts,
which first-person games need. The other device's pointer is drawn over the
picture meanwhile. The same keys, or leaving the window, free it.

### Viewing (`app/windows/runner/desktop_texture.cpp`, `DesktopView`)

On Windows the decoder (Media Foundation's H.264 MFT, low-latency mode, on
the GPU through DXVA where it can, in software otherwise) runs on its own
thread, converts NV12 to RGBA (on the GPU, or on the CPU after software
decoding) into a triple buffer, and tells the runner a frame is ready;
Flutter's texture registry copies it on the raster thread. Sound plays
through WASAPI with at most ~120 ms waiting (`desktop_audio.rs`, a jitter
buffer that drops the oldest rather than fall behind).

On Android (`DesktopDecoder.kt`) each frame goes over a method channel to a
hardware `MediaCodec` decoder in low-latency mode, which renders straight
into a Flutter `SurfaceProducer` texture; sound goes to a low-latency
`AudioTrack` that skips a chunk rather than lag.

The `DesktopView` widget (plugin UI library) shows the texture letterboxed
with a toolbar: figures, sound, display, pointer lock (Windows), keyboard
and clipboard (phones), full view. With a mouse the pointer goes where it
points. With touch: a tap clicks, a finger held still right-clicks, a moved
finger drags, two fingers scroll, a two-finger tap right-clicks; the other
device's pointer is drawn so you can see where you are. A phone's keyboard
types through a hidden text field; a phone sends its clipboard only when
asked, since reading it unasked would be announced each time.

## Permission

Receiving starts off, and has two switches in the plugin:

1. **Allow remote desktop**: this person's own devices may connect.
2. **Let friends ask**: a friend's device may ask to connect.

When a device connects:

1. The viewer's plugin sends a live `start` request; the receiver's plugin
   checks its switches and calls `remote-desktop.admit()`, which admits the
   device whose request it is answering.
2. For one of this person's own devices that is all. For a friend's, Dart
   asks the person at the receiving device, **every time**, in a dialog
   naming the friend and the device (`Plugins.confirmDesktop`, app.dart);
   no answer in 23 seconds is no. The plugin cannot answer for them: the
   import waits on Dart, and Dart refuses friends outright where there is
   no one to ask.
3. Dart then accepts one `desktop` connection from that device within 15 s.
4. While streaming, the receiver shows the **Being controlled by …** banner
   (capability `remote-desktop`), and **Stop** ends the stream and switches
   both receiving switches off.
5. Clipboard text never goes to or comes from a friend's device: the served
   side switches it off for anyone not certified to this person.

The grant is `remote-desktop` (API 0.6). The native host still holds the
other device capabilities (`remote-input` and the rest) to own devices
only; `remote-desktop` is not in that list because Dart asks the person.

## Using it

Install **Remote Desktop** from Settings › Plugins on both devices. On the
one to be viewed, switch on **Allow remote desktop** (and **Let friends
ask** if friends should be able to ask). On the other, choose that device
and a quality (720p, 1080p, 1440p or native, each at 60 fps) and press
**Connect**. Click or tap the picture to control it; Ctrl+Alt+Shift+F
toggles the full view and Ctrl+Alt+Shift+L the pointer lock. **Preview this
screen** runs this device's own screen through the same capture, encoder
and decoder without the network or control: a quick check that it works on
a machine.

## Measured (25–26 October 2026, laptop with an RTX 4090, 2560×1600 desktop)

Debug-profile native code (`native-dev`), streaming at 1920×1200:

- Capture, GPU conversion and NVENC encoding: 3–5 ms a frame.
- Capture to the viewer's acknowledgement between two nodes on this
  machine over QUIC: 3–6 ms.
- The software MFT encoder (forced) takes 7–10 ms a frame.
- Decoding on the GPU (DXVA), converting to RGBA there and reading the
  picture back: 2.4–3 ms a frame at 1280×800 in the app, 4–7 ms at
  1920×1200. The software decoder it falls back to took 18–23 ms.
- Sound capture: 100 chunks of 10 ms a second while something plays.
- The in-app preview (integration_test/remote_desktop_test.dart) draws the
  picture through the runner's texture.

Alex confirmed viewing a Windows desktop from Android works (0.2.55). Not
measured: two physical machines over a real network, and games.

## Not yet

- Error correction: video rides one reliable QUIC stream, so a lost packet
  holds the next frames for a round trip (a few ms on a LAN, tens over the
  internet). Datagrams with FEC and per-frame recovery would remove that
  stall; the bit rate adaptation and frame pacing above keep it short.
- Zero-copy viewing on Windows: hand the decoded RGBA texture to Flutter as
  a shared `GpuSurfaceTexture` instead of reading it back into a pixel
  buffer that Flutter uploads again.
- Sound compression (Opus) for slow links; sound playback is untested on a
  real pair of devices.
- Moving the stream pump off the UI isolate (or into one native iroh, phase
  4 of PLUGINS.md).
- Receivers on other platforms; pointer lock on Android with a mouse.
