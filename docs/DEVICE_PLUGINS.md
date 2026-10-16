# Between your own devices

Device Dashboard and Remote Input are bundled plugins. Install each from
Settings → Plugins on both devices. They use existing encrypted live requests,
not stored objects: clipboard contents, input and resource samples are never
added to your shared history. Both accept requests only from devices certified
as belonging to your own identity. A friend running the same plugin gets no
access.

Receiving permissions start off whenever a plugin starts, including a restart
or update. Installation grants allow the plugin to use the host capability;
the plugin's own controls determine whether another device may use it now.
Switching off or removing the plugin stops receiving. Receiving requires
OurNet to remain running and reachable; Android background execution is not
guaranteed.

## Device Dashboard

On the Windows machine, choose **Share this device's metrics**. On the phone,
select that computer, then Refresh or **Watch for 5 minutes**. The watch
samples every two seconds, keeps at most 60 CPU readings in memory and stops
after five minutes; resume explicitly. It does not read object history.
**This device** can inspect local Windows metrics without enabling sharing.
Plugin device names are maintained through an incremental insertion cursor,
so repeated contact lookups consume each rename once, including on long histories.

The host supplies CPU usage, physical memory, network receive/send rates,
uptime and any available temperature sensors. The first CPU/network reading
is marked as sampling because rates need two samples. GPU utilisation and
fan speeds are currently unavailable; this is stated in the UI, and absent
temperature sensors do not appear as zero readings.

Processes are refreshed at most every three seconds and the reply includes
the top 128, ordered by CPU then memory. Process termination requires the
separate **Allow ending processes** switch on the receiving machine and
confirmation on the controller. Disabling sharing also disables termination.
The native host requires a previously sampled PID and its matching start time,
refuses low system PIDs and OurNet itself, and honours Windows permissions.
There is no arbitrary shell or administrator escalation.

## Remote Input

Enable **Allow incoming mouse / keyboard** and/or **Allow incoming clipboard**
on the receiving device, then select it on the controller. The permission
switches are independent. **Stop all incoming control** disables both.

- **Type** sends text as Unicode keyboard input into the focused Windows app.
- **Copy** writes text into the destination clipboard without pasting.
- **Paste** writes the clipboard and presses Ctrl+V; both receiver switches
  must be on before the clipboard is changed.
- The touchpad sends bounded relative movement; separate buttons click and
  scroll. Navigation, presentation and media buttons send named key presses.
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
