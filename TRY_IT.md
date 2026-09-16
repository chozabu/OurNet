# Try the new prototype

For OurNet 0.2 private drive testing, see [PRIVATE_DRIVE.md](PRIVATE_DRIVE.md).
Community cards now have an Open discussion action and indented replies. On a
hardware keyboard, Enter sends and Shift+Enter inserts a newline.

The old prototype is unchanged. This app uses its own identity vault entries and
database files, and speaks a new protocol incompatible with the old app.

## Windows

From PowerShell in `D:\git\OurNetAS`:

```powershell
.\tool\run.ps1 -Profile alice
.\tool\run.ps1 -Profile bob
```

This opens the release build in two visible windows with independent identities.
Use `-Debug` if you specifically want the debug executable. Do not open the same
profile twice. `-Build` creates a new dated release package from a source snapshot;
it does not overwrite running release binaries. Close a profile's old window
before launching that same profile on the new build. For hot reload instead:
`cd app; flutter run -d windows`.

On a fresh checkout, run `.\tool\setup.ps1` first. It resolves packages and
verifies the upstream signature of the pinned native networking library.

1. In each window, open Profile and set a different name.
2. In each window, open Settings and choose **Connect locally** for a test that
   does not need external discovery/relays. **Connect** in the top bar uses
   internet mode and iroh's default infrastructure.
3. In Network, copy Alice's contact card and add it in Bob's window. Copy Bob's
   card and add it in Alice's window. Both sides must add the other.
4. In Messages, select the other person and send a message. **Sync now** can force
   a catch-up. Inspect the verification icon to see signed handoffs and receipts.
5. Post in the `general` community. Both profiles initially subscribe to it.
   Subscribe to `files` to receive public file publications.
6. Attach a file to a private message or publish one in Files. The receiving
   window downloads it on request while an author or admitted holder is online.
7. Locations lets you share coordinates privately with a chosen person for one
   hour. Voting supports direct votes and topic-specific delegation.

Voice/video controls are in Messages. Both apps must be connected and running.
Microphone/camera access is requested by the media implementation when used.
Outside a reachable local network, configure your own STUN/TURN servers under
Settings if direct media connectivity fails. Media does not inherit iroh's relay
path. Real microphone/camera and wide-area call behaviour still need validation.

## Android

Connect your phone with USB debugging enabled and accept its authorisation prompt:

```powershell
.\tool\update-android.ps1 -Desktop
```

This builds and updates Android without clearing its profile or files, launches
the phone app, and builds/opens a fresh Windows package. Omit `-Desktop` for phone
only. Use `-Device SERIAL` when multiple devices are connected, `-Profile alice`
to choose the desktop profile, or `-SkipBuild` to reuse existing builds. Close
the previous window for that desktop profile before launching its replacement.

The debug APK is built at:

`app\build\app\outputs\flutter-apk\app-debug.apk`

Install it as a development APK on your own device, or use
`flutter run -d <device-id>` from `app`. The package is `org.chozabu.ournet`, separate
from the old prototype. APK compilation has been checked; on-device behaviour
must still be verified. Background receipt while the app is suspended is not
promised. Private messages use encrypted device envelopes, not a forward-secret
ratcheting messaging protocol.

## Adding a device to your existing identity

On first launch, choose **Create a profile** on your PC. In Profile, open
**Add device**. On your phone choose **Connect to my existing profile**, then
**Scan QR code**. Nearby discovery on the same LAN and copying/pasting the
invitation are alternatives. Compare the displayed code and approve on the PC.
Invitations expire after five minutes and can enrol only one device. Contacts
are exchanged automatically and sync starts when setup finishes.

Existing profiles open normally. An empty profile from an earlier build can
join via Profile → **Connect this empty profile to my existing profile**.
Profiles containing content cannot be merged through device pairing.
The original device retains the root key. Existing drive history is shared by
default, with an opt-out before approval; old private chat history is not migrated.

## Development checks

```powershell
cd core
dart test
cd ..\app
flutter test
flutter analyze
```

The network test uses two real local iroh endpoints and the verified desktop
library. Core tests require neither Flutter nor Rust compilation.

Or run `tool/check.ps1` from the repository root to check all three packages.
See `PARITY.md` for completed checks and remaining hands-on verification.
