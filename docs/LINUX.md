# Linux

## Building

On Ubuntu 24.04 or similar, with Flutter and a Rust toolchain:

```sh
sudo apt-get install ninja-build libgtk-3-dev liblzma-dev libsecret-1-dev \
  libjsoncpp-dev libayatana-appindicator3-dev libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev libpulse-dev
tool/setup.sh            # dependencies + the signed iroh library
cd app && CARGO_OURNET_NATIVE_PROFILE=release flutter build linux --release --no-tree-shake-icons
```

The bundle is `app/build/linux/x64/release/bundle`; run `ournet` in it.

## Flatpak

`.github/workflows/linux.yml` builds the bundle and packages it with
`app/linux/flatpak/io.github.chozabu.OurNet.yml`, uploading `OurNet.flatpak`
as an artifact. Install it with `flatpak install --user OurNet.flatpak`
(Steam Deck: in Desktop Mode). To build it locally, clone
`flathub/shared-modules` into `app/linux/flatpak/shared-modules` (the commit
the workflow pins) and run
`flatpak-builder --user --install --force-clean build-dir app/linux/flatpak/io.github.chozabu.OurNet.yml`.

The app ID is `io.github.chozabu.OurNet`, which Flathub can verify through
the GitHub account.

## How Linux differs

- **Identity keys** are kept in a file only this person can read, beside the
  profile's database (`app/lib/services/vault.dart`), not in the Secret
  Service: Steam Deck's Game Mode has none, and an empty read would make a new
  identity.
- **Tray and sign-in start** (`app/linux/runner/system_tray.cc`): a
  StatusNotifierItem icon where the desktop shows one (KDE, Deck Desktop
  Mode), via libayatana-appindicator; starting on sign in through the
  Background portal under Flatpak, or `~/.config/autostart` otherwise.
  Without a tray host, OurNet does not keep running after its window closes.
- **One window per profile**: GApplication uniqueness; opening OurNet again
  shows the running window.
- **Not on Linux yet**: VPN plugins (need `/dev/net/tun` with network admin
  rights, which Flatpak cannot grant), voice transcription (`ournet_speech`
  has no Linux build), QR scanning and text recognition (mobile only).
