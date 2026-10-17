# Between your own devices

Device Dashboard and Remote Input are bundled plugins. Install each from
Settings → Plugins on both devices. They use existing encrypted live requests,
not stored objects: clipboard contents, input and resource samples are never
added to your shared history. Both accept requests only from devices certified
as belonging to your own identity. A friend running the same plugin gets no
access.

## Own devices only, in the host

The plugins check this themselves, and the host enforces it whatever a
plugin does. When Dart hands a plugin a live request it says whether the
sending device is this device or one certified to this identity and not
revoked (`Node.ownDevice`). While the plugin answers that request, the native
host (`on_behalf` in `native/rust/src/plugin.rs`) refuses `system-monitor`,
`process-control`, `remote-input` and `clipboard-write` unless it is: the
error is "… is only for your own devices", and nothing is sampled, ended,
typed or copied. Events and timers act for the person at the device, as
before. A plugin could still save a friend's request and act on it later
from a timer; that is a malicious plugin, which these grants already trust,
not a check it can get wrong by accident.

## Seeing who is connected

While another of your devices uses one of those capabilities here, every
page of the app shows a banner: **Being viewed by …** (resources only) or
**Being controlled by …** (input, clipboard or ending processes), naming the
devices and plugins. **Stop** ends the sessions here by restarting those
plugins, which switches their receiving permissions off; **Log** opens the
session log. The plugins' own pages show the same.

The host reports use at most once a second per device and capability; a
session ends 12 seconds after its last use. The log records sessions
starting and ending, each capability first used, and every process ended
remotely (name and PID). It holds the latest 200 entries in memory and is
lost when OurNet closes: never stored, synced or added to history, and never
any typed or clipboard text. Settings → Plugins → **Remote sessions** shows
it too.

Receiving permissions start off, and once switched on stay on across
restarts and updates (kept in the plugin's storage on that device) until
switched off. **Stop** in Remote sessions switches them off too: it sends
each plugin serving a session a `disable` event, then restarts it. Installation grants allow the plugin to use the host capability;
the plugin's own controls determine whether another device may use it now.
Switching off or removing the plugin stops receiving. Receiving requires
OurNet to remain running and reachable; Android background execution is not
guaranteed.

## Device Dashboard

On the Windows machine, switch on **Share this device's metrics**. On the
phone, pick that computer from the device menu. While the dashboard is on
screen with a device chosen, it streams: every second by default (2 or 5
seconds from the interval menu), until you **Pause**. It stops when the page
closes, the app goes to the background or the plugin stops, and resumes when
the page shows again. One request is in flight at a time; after a failure
it waits 5 seconds. Each series keeps the latest 60 samples, and per-core
charts at most 64 cores, so memory stays bounded however long it runs. It
does not read object history. **This device** shows local metrics without
enabling sharing.

**Performance** works like Task Manager's: tiles for CPU, memory, network,
disk and (when exposed) temperature, each with a sparkline; the selected one
opens a large chart and its figures. CPU shows utilisation, speed, the
process, thread and handle counts, up time, logical processors and cores,
and a chart per logical processor; memory shows in use, available, commit
charge and swap; network receive and send; disk read and write rates and
each volume's space. On a phone the tiles sit in a grid above the detail; on
a wide window they are a column beside it.

**Processes** lists the 512 busiest processes (by CPU, then memory), with
name, PID, CPU (as a share of all processors, as Task Manager shows it),
memory and disk rate. The table sorts by any column and filters by name or
PID in the app, without waiting for the plugin, keeps its scroll position
and selection as samples arrive, and shades busy cells. Process rows are
only requested while this tab is shown.
Plugin device names are maintained through an incremental insertion cursor,
so repeated contact lookups consume each rename once, including on long histories.

The host supplies CPU usage, physical memory, network receive/send rates,
uptime and temperatures. Temperatures come from the ACPI thermal zones
Windows publishes as performance counters (`\Thermal Zone Information(*)`),
NVIDIA GPUs through the driver's NVML library (loaded only from the system
or NVIDIA directory), and any WMI sensors sysinfo can read; none of these
needs administrator rights except WMI's, which is retried every 30 seconds
while empty. NVML also gives each NVIDIA GPU's load and dedicated memory,
shown as a GPU tile. All of it is read on the sensor worker. The first
CPU/network reading is marked as sampling because rates need two samples.
Other GPUs' load and fan speeds are unavailable; this is stated in the UI,
and absent temperature sensors do not appear as zero readings.

Processes are refreshed at most every two seconds. Current controllers ask
for compact rows (`v: 2`, `processRows`); an older controller still gets
the top 128 as objects. To end one, select it and choose **End task**, then
confirm (sampling pauses while you decide). It needs the separate **Allow
ending processes** switch on the device whose process it is, and for another
device also sharing; disabling sharing also disables it. The native host
requires a previously sampled PID and its matching start time, refuses low
system PIDs and OurNet itself, and honours Windows permissions. There is no
arbitrary shell or administrator escalation.

The native sampler adds, beside the earlier figures: per-core usage, CPU
brand and frequency, core counts, available memory and swap, commit charge,
process/thread/handle counts (one `GetPerformanceInfo` call), each volume's
space and read/write rates, and per-process disk rates. Volumes and
temperatures are read on the one background sensor worker: the volume list
every 30 seconds, counters every second, so a slow disk or WMI provider
cannot hold up a sample.

## Remote Input

Switch on **Allow incoming mouse / keyboard** and/or **Allow incoming
clipboard** under **Receive on this device**, then pick that device under
**Control** on the controller. The permission switches are independent.
**Stop all incoming control** disables both. The controller shows whether it
is connected and what the chosen device currently accepts (it asks every 5
seconds while the page is shown; the question touches nothing), and the
receiver shows who is controlling it.

On a phone the controls are tabs: **Touchpad** (with the most used keys
below it), **Keys** (arrows, Esc, Tab, Enter, Space, Backspace, Delete, Home,
End, Page up/down, and presentation keys: previous/next slide, start the
show with F5, end it, full screen with F11), **Text** and **Media**. A wide
window shows the touchpad and text beside the keys, presentation and media
groups.

- **Type** sends text as Unicode keyboard input into the focused Windows app.
- **Copy** writes text into the destination clipboard without pasting.
- **Paste** writes the clipboard and presses Ctrl+V; both receiver switches
  must be on before the clipboard is changed.
- The touchpad is a large surface: drag one finger (or the mouse) to move,
  tap to left-click, tap with two fingers or hold to right-click, and drag
  two fingers, or one finger along the strip at its right edge, to scroll.
  A mouse wheel over it scrolls. Left and right buttons sit below it. Moves
  are sent at most once a frame, faster strokes travel further, and the pad
  claims its touches, so the page does not scroll under a finger.
- Navigation, presentation and media buttons send named key presses. Space,
  Delete, Home, End, F5 and F11 are new; an older receiver answers "Unknown
  key".
- Dictation uses the microphone button on the phone's normal keyboard.

Text is limited to 16 KiB of UTF-8. Clipboard access is write-only; there is
no clipboard reader, automatic synchronisation or clipboard history. A failed
paste can leave the clipboard updated, for example if Windows refuses input
into an elevated application. The error is shown to the controller.

The sender coalesces movement, allows one live request and one queued explicit
action, and drops queued work on an error or timeout. Requests are never
retried automatically. The receiver caps input at 60 requests/second. There
are no held modifiers or held mouse buttons across requests, so disconnecting
cannot leave a remote key deliberately held down.

Windows currently receives mouse, keyboard and resource monitoring. Android
can control a Windows receiver and receive explicit clipboard writes through
Flutter's platform clipboard API. Other platforms return an explicit error
for unsupported native capabilities. Physical Android input/clipboard and
background behaviour still need device validation.

## Host API 0.3

The WIT world is unchanged by the changes above. The host also posts
`device.session` and `device.action` notices for the receiver's banner and
log, and reads an optional `own` flag on request calls. The plugins are
version 0.2.0; their JSON stays additive (`v`, `processRows`, `status`), so
mixed versions keep working.

Four additive WIT interfaces and manifest grants:

| Interface / grant | Operation |
|---|---|
| `system-monitor` | `snapshot(processes)` → JSON, sampled on the plugin thread |
| `process-control` | `stop(pid, started)` with sampled-process and PID-reuse checks |
| `remote-input` | `execute(command)` with bounded JSON and a fixed operation/key vocabulary |
| `clipboard-write` | `write(text)` through an app callback, with a per-call grant check |

The native SDK exposes these as `ournet_plugin::device`. Existing WIT
interfaces and network request types retain their meaning. Packages declare
API 0.3 so older apps reject them clearly. No peer minimum is raised. The JS
runtime does not yet expose these new capabilities.

Windows monitoring uses the maintained `sysinfo` crate with persistent sampler
state and specific CPU/memory/process refreshes. Windows input uses `SendInput`
directly, on the plugin thread. OS input restrictions (locked desktops,
elevated applications) still apply. The app callback writes the clipboard
asynchronously; there is no synchronous clipboard I/O in widget callbacks.
Temperature providers run on one process-wide background worker with a
one-request queue and a bounded cache; a slow or hung WMI provider cannot
block resource samples. Missing sensors are retried at most every 30 seconds.

## 0.2.41 validation

Package analysis passed. Core passed 398 tests, transport passed 75, and the
app passed 264 with two skips and one existing location-reconnect failure
(`location_share_test.dart`, missing position after reconnect; also failed
in isolation). The new plugin host, permission, clipboard, incremental-name
and phone-layout tests passed, as did the native capability tests.

Windows profile measurements on 16 October 2026 are not a performance baseline:
the laptop was thermally constrained with performance limited. The import
responsiveness run measured p95 18.406 ms against a 16.667 ms budget; the
photo/map suite passed. Remaining profile checks were stopped at the user's
request. No timing assertions were changed. Physical Android validation was
unavailable.

## Plugin 0.2.0 validation (16 October 2026)

Native tests passed, including the host's own-device admission test and the
extended sampler test (per-core, counts, commit, 512-row bound). Core passed
400 tests with two skips, including the new host-refusal and session-log
tests: a request whose device Dart does not certify is refused by the host
even though the plugin accepts it. The app passed 267 with two skips and the
same location-reconnect failure as before (`location_share_test.dart`). The
new plugin-view tests draw both plugins at phone and desktop widths with
live local samples, select a process in the table and walk the End-task
confirmation without ending anything, and check the receiver's banner, log
and Stop. Analysis is clean.

After rebasing onto the dependency updates and adding thermal-zone and
NVIDIA temperatures: native 4 passed (the sensor test reads two thermal
zones and an RTX 4090 without administrator rights), core 400 with two
skips, and the app 268 with two skips; analysis clean.

The Windows debug build starts with the new native host. The plugins were
not driven by hand in the running app, nor between two real devices; the
widget tests run the real native host and plugins instead. Android remains
unvalidated, and no profile-mode timing was measured.
