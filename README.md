# OurNet

OurNet is a serverless app for messaging and notes. It shares your data directly
between your own devices and the people you trust, with no central platform in
between.

Most communication tools depend on a company's servers: they hold your data,
decide who can reach you, and give you little way to tell where information came
from. OurNet is an alternative built on a **friend-to-friend** (F2F) network,
inspired by RetroShare. Devices connect peer-to-peer, and data only travels
between people who have chosen to connect.

The focus is on **identity, accountability and trust**:

- **Persistent identity.** You have one identity that your friends recognise. It
  works across your phone and PC, and it isn't tied to any device or provider.
- **Accountability.** Content is signed and carries a record of who wrote it and
  which people passed it along, so you can judge what you receive and trace
  misuse.
- **Trust in context.** Being someone's friend doesn't grant access to
  everything. Folders, groups and lists are encrypted and shared only with the
  people you pick.

Today it covers Keep-style notes and checklists (including voice notes with
on-device transcription), 1:1 and group conversations, file sharing, private
groups with shared lists, and private drive sync across your own devices. It
runs on Windows and Android. The longer-term vision, which includes communities,
wikis, maps and calls, is described in [CORE_IDEA.md](CORE_IDEA.md).

> **Status:** early prototype. The encryption scheme has not been audited, and
> the protocol may change without migration. Don't rely on it yet for sensitive
> data.

## About this prototype

This is the second prototype; it intentionally does not interoperate with the
old Rust prototype (`ournetcc`).

**Start here: [TRY_IT.md](TRY_IT.md).** Windows and Android debug builds are
available locally. The current validation and remaining work are recorded in
[PARITY.md](PARITY.md).

OurNet 0.2 adds [private drive and device sync](PRIVATE_DRIVE.md), threaded
discussion navigation, and Enter/Shift+Enter composition. See
[PERFORMANCE.md](PERFORMANCE.md) for repeatable measurements. Run
`tool/package.ps1 -Android` to build a dated Windows ZIP and Android debug APK
with SHA-256 sidecars. Packaged Windows folders contain `Launch.ps1` and can be
replaced without deleting profile data. Settings shows the version/build ID and
can copy basic diagnostics without keys or message contents.

See [Everyday sharing](EVERYDAY.md) for My inbox, Android sharing, private groups,
shared lists, delivery behavior, and validation.

## Structure

- `core`: pure Dart identity, signatures, encrypted objects, SQLite storage,
  replication policy, provenance, revocation and vote resolution.
- `transport`: pure Dart iroh networking, attachment transfer and a headless
  personal node. It has no Flutter dependency.
- `app`: Flutter UI, OS key vault, file/clipboard integration, notifications and
  WebRTC calling. Screens are grouped by feature under `lib/ui`.
- `vendor/iroh_mobile`: pinned upstream Android native plugin. Our application
  has no handwritten Rust business logic or generated application FFI bridge.
- `tool`: setup and independent-profile launch scripts.

Windows uses a signed precompiled upstream networking DLL. Android currently
builds the vendored native library once; later Dart/UI edits do not require Rust
source changes. Keep the lockfiles committed. See `vendor/README.md` for origins.

## Development

Install Flutter with Dart, Windows C++ build tools for Windows, and the Android
SDK/NDK and Rust Android targets for Android. The current checkout was built with
Dart 3.12.2; `flutter doctor` reports local toolchain readiness.

```powershell
.\tool\setup.ps1
cd core
dart test
cd ..\transport
dart test
cd ..\app
flutter test
flutter analyze
flutter run -d windows
```

The core test loop does not load iroh or Flutter. Transport tests run actual
local QUIC endpoints, including unadmitted caller rejection and private file
access checks. Flutter tests cover navigation, phone layouts and the UI adapter.

For an interactive headless personal node, run from `transport`:

```powershell
dart run bin/node.dart my-node-data --local
```

The CLI asks for a vault password, stores an encrypted identity vault and SQLite
content in the chosen directory, and accepts `card`, `add <card>`, `sync`,
`subscribe <space>`, `post <text>`, and `quit`. It is an initial operator interface,
not yet a packaged background service or a multi-user hosting server.

## Product and protocol

Read [CORE_IDEA.md](CORE_IDEA.md), [PROTOCOL.md](PROTOCOL.md), and the historical
[PROTOTYPE_REVIEW.md](PROTOTYPE_REVIEW.md). Provenance proves signed statements
about recorded actions, not truth, real-world identity, or off-protocol copying.
The current encryption is a prototype device-envelope scheme; forward secrecy,
identity recovery and encrypted history migration remain separate work.

