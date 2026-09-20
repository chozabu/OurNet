# Microsoft Store submission

Copy for Partner Center, product `9N6P4X13QG9M` (identity `Chozabu.OurNet`).
Updates after the first submission go through `tool/publish-store.ps1`.

## Pricing and availability

Free, all markets, public. No trial, no sale.

## Properties

- **Category:** Social (subcategory: none). Productivity also fits.
- **Privacy policy URL:** https://github.com/chozabu/OurNet/blob/main/PRIVACY.md
  (push the Windows update to `PRIVACY.md` first)
- **Website:** https://github.com/chozabu/OurNet
- **Support contact:** chozabu@gmail.com
- **Product declarations:** leave all unticked. It has no in-app purchases, and it
  does not depend on non-Microsoft drivers or NT services.
- **System requirements:** none beyond Windows 10 1809 (the package minimum).
  Microphone and camera are optional (voice notes and calls).

## Age ratings (IARC questionnaire)

Category: **Social networking / communication**.

- Violence, fear, sex, language, drugs, gambling: **No** (the app ships no
  content; everything comes from the user's own friends).
- Users can interact or exchange content with each other: **Yes**.
- Shares the user's location with other users: **Yes**. Users can post a
  location they type in to friends. The app never reads the device location,
  but the conservative answer costs nothing.
- Digital purchases: **No**.
- Unrestricted internet access, such as a browser: **No**.

Expect a rating of about 12+ / PEGI 12 with "Users Interact" and "Shares Location".

## Store listing (English)

**Product name:** OurNet

**Short description** (the 270-character version below also works for "short"):

> Notes, messages and files shared directly between your own devices and the
> people you trust. No servers, no accounts.

**Description:**

> OurNet is a serverless app for notes and messaging. It shares your data
> directly between your own devices and the people you trust, with no company
> platform in between.
>
> • Notes and checklists, with voice notes transcribed on your device
> • One-to-one and group conversations, with voice and video calls
> • Share files and photos with friends, or keep a private drive in sync across
>   your own PC and phone
> • Private groups with shared lists, visible only to the people you choose
> • One identity your friends recognise, across Windows and Android
> • Everything you receive is signed, so you can see who wrote it and who
>   passed it along
>
> There is no sign-up and no OurNet server. Devices connect peer-to-peer and
> encrypt what they send. When a direct connection is impossible, encrypted
> traffic may pass through a relay that cannot read it.
>
> OurNet can stay in the notification area when you close the window, so
> messages still arrive, and it can start when you sign in. Both are optional,
> in Settings.
>
> OurNet is an early release. The encryption has not yet been independently
> audited.

**What's new in this version:** First Microsoft Store release.

**Product features** (one per line, up to 20):

```
Notes and checklists
Voice notes with on-device transcription
Direct and group messaging
Voice and video calls
File and photo sharing
Private drive sync across your devices
No accounts and no central server
Signed content with visible provenance
```

**Search terms** (up to 7): `peer to peer`, `private messaging`, `notes`,
`friend to friend`, `encrypted`, `file sharing`, `serverless`

**Copyright:** © 2026 Alex P-B

**Images:**
- Store logos: `store/ournet-icon-512.png` (1:1, 300x300 is enough).
- Screenshots: `store/screenshots-windows/*.png` are the Windows app at
  1920x1080 and are the ones to submit. `store/screenshots-windows/raw/`
  holds the unframed window captures behind them.
  `store/screenshots/*.png` are the Android app at 1080x1920, kept for Play.
- Hero image (optional, 16:9, 1920x1080): not yet made.
  `store/ournet-feature-1024x500.png` is the wrong ratio.

## Submission options: notes for certification

> OurNet is a Flutter desktop (Win32) app packaged as MSIX, so it needs
> runFullTrust. It uses a notification-area icon (Shell_NotifyIcon) that keeps
> the app connected to friends after its window is closed, a Windows startup
> task that is off by default and set from Settings, Windows speech recognition
> and Media Foundation for voice notes, and native peer-to-peer networking
> (QUIC via iroh, WebRTC for calls). The package declares an inbound UDP
> firewall rule so friends' devices can connect directly. It installs no
> drivers or services and never asks for elevation.
>
> Testing: no account or login is needed. On first launch, choose a name to
> create a local identity. Notes, checklists and voice notes work on one
> machine. Messaging and calls need a second device running OurNet (another PC
> with this app, or the Android app). On each device, use Add friend to
> exchange invites. Both must be online.
