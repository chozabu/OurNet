# OurNet privacy declaration

_Last updated: 19 September 2026. Applies to OurNet for Android (`org.chozabu.ournet`)
and Windows (the Microsoft Store app `Chozabu.OurNet`, and the zip download)._

## The short version

OurNet is a friend-to-friend program. There is no OurNet server holding your
notes, messages or files, and no account to sign up for. Your identity, your
keys and your content live on your own devices. We do not collect your data,
because there is nowhere for us to collect it to.

## What we collect

Nothing. The developer operates no servers that receive your content, and the
app contains no analytics, advertising or crash-reporting SDKs.

## What leaves your device

**To your friends' devices.** Notes, files, photos, messages and call media you
choose to share are sent to the devices of people you have admitted. Content is
encrypted in transit and carries a signed record of its origin.

**Through relay servers, sometimes.** OurNet uses [iroh](https://iroh.computer)
for transport. It tries to connect your device directly to your friend's
device. When a direct connection cannot be established — typically because of
NAT or a restrictive firewall — traffic may be routed through a public relay,
by default one operated by [number 0](https://n0.computer). Relays forward
encrypted packets and cannot read your content, but the relay operator can
observe connection metadata: which nodes connect to which, when, and from what
IP address. Voice and video calls use WebRTC, which contacts STUN servers
(by default Google's and Cloudflare's, or ones you configure) to learn your
public address; those operators see your IP address when you place or answer a
call, but not the call itself.

**To a speech service, if you choose one.** Voice notes can be transcribed by
Whisper, which runs on your device; downloading a Whisper model fetches it from
Hugging Face, which sees your IP address. If you choose the system speech
engine instead, your recording goes to that engine: on Windows, Microsoft's
online speech recognition (only while it is turned on in Windows privacy
settings); on Android, your phone's speech service. Their own privacy terms
apply to that audio.

These are the only categories of information that reach a third party, and we
would rather say so plainly than claim nothing ever leaves.

**Nowhere else.** No content is sent to the developer.

## What stays on your device

- Your private keys, held in Android's key store, or on Windows encrypted to your
  Windows account
- Your notes, files and message history, in a local database
- Text recognised from images, which is processed on-device

## Permissions and why

| Permission | Why |
|---|---|
| Internet | Connecting to your friends' devices |
| Camera | Taking photos for notes, scanning pairing QR codes, video calls |
| Microphone | Voice notes and calls |
| Notifications | Telling you about new messages, replies, calls and note reminders. By default a message notification shows the sender and text, which your phone can hide on the lock screen; Settings can limit it to the sender |
| Run at startup / exact alarms | Re-scheduling note reminders after a restart (Android); starting in the notification area when you sign in, only if you turn it on in Settings (Windows) |
| Incoming network connections (Windows firewall) | Letting your friends' devices connect directly to yours |

Camera and microphone are used only while you are actively using the feature
that needs them.

## What you control

- Who you admit as a friend, and who you block or revoke
- Which devices carry your identity, and removing one you no longer have
- What you share, with whom, and at what scope
- Whether to run your own node rather than rely on any shared infrastructure

## Deleting your data

Uninstalling OurNet removes the local database and keys from that device. On
Windows, the zip download keeps them in `%APPDATA%\org.ournet\ournet` until
you delete that folder, and so does the Store app if that folder was there
before it was installed.
Content you have already shared exists on your friends' devices and is not
recallable — the same as any message you have already sent someone.

## Open source

OurNet's source is published, so these claims can be checked rather than taken
on trust. If you find that the code and this document disagree, the code is the
truth and this document is the bug — please report it.

## Contact

chozabu@gmail.com
