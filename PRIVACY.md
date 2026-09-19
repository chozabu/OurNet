# OurNet privacy declaration

_Last updated: 16 September 2026. Applies to OurNet for Android (`org.chozabu.ournet`)._

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

This is the one category of information that reaches a third party, and we
would rather say so plainly than claim nothing ever leaves.

**Nowhere else.** No content is sent to the developer.

## What stays on your device

- Your private keys, held in the operating system's key store
- Your notes, files and message history, in a local database
- Text recognised from images, which is processed on-device

## Permissions and why

| Permission | Why |
|---|---|
| Internet | Connecting to your friends' devices |
| Camera | Taking photos for notes, scanning pairing QR codes, video calls |
| Microphone | Voice notes and calls |
| Notifications | Telling you about new messages, replies, calls and note reminders. By default a message notification shows the sender and text, which your phone can hide on the lock screen; Settings can limit it to the sender |
| Run at startup / exact alarms | Re-scheduling note reminders after a restart |

Camera and microphone are used only while you are actively using the feature
that needs them.

## What you control

- Who you admit as a friend, and who you block or revoke
- Which devices carry your identity, and removing one you no longer have
- What you share, with whom, and at what scope
- Whether to run your own node rather than rely on any shared infrastructure

## Deleting your data

Uninstalling OurNet removes the local database and keys from that device.
Content you have already shared exists on your friends' devices and is not
recallable — the same as any message you have already sent someone.

## Open source

OurNet's source is published, so these claims can be checked rather than taken
on trust. If you find that the code and this document disagree, the code is the
truth and this document is the bug — please report it.

## Contact

chozabu@gmail.com
