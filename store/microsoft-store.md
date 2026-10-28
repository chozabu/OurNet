# Microsoft Store submission

Copy for Partner Center, product `9N6P4X13QG9M` (identity `Chozabu.OurNet`).
Updates after the first submission go through `tool/publish-store.ps1`.

## Pricing and availability

Free, all markets. No trial, no sale.

**Discoverability:** available by direct link only, not shown in Store search
(set in Submission 2, September 2026). Packages uploaded by
`tool/publish-store.ps1` keep this setting; changing it takes a new submission.
The overview page's availability toggle blocks installs entirely instead.

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
- Shares the user's location with other users: **Yes**. Users can share their
  device location with friends they choose (precise or approximate, per
  friend), and share saved places.
- Digital purchases: **No**.
- Unrestricted internet access, such as a browser: **No**.

Expect a rating of about 12+ / PEGI 12 with "Users Interact" and "Shares Location".

## Store listing (English)

**Product name:** OurNet

**Short description** (the 270-character version below also works for "short"):

> Notes, messages and files shared directly between your own devices and the
> people you trust. No servers, no accounts.

**Description, product features and what's new** are in
`store/microsoft-listing.json`. `python tool/store_listing.py` sends them,
with the screenshots, as a new submission (same package); `--dry` checks
without committing. Last sent 2026-10-28.

**Search terms** (up to 7): `peer to peer`, `private messaging`, `notes`,
`friend to friend`, `encrypted`, `file sharing`, `serverless`

**Copyright:** © 2026 Alex P-B

**Images:**
- Store logos: `store/ournet-icon-512.png` (1:1, 300x300 is enough).
- Screenshots: `store/screenshots-windows/*.png` are the Windows app at
  1920x1080 and are the ones to submit; `store/screenshots/*.png` are the
  phone layout at 1080x1920, for Play. Both are drawn with made-up people by
  `app/test/store_shots_test.dart` and framed by `tool/store_shots.py`
  (its docstring has the two commands).
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
