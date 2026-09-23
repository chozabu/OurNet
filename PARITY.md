# Prototype parity and validation

Updated 22 September 2026. This tracks working behaviour, not placeholder screens.
Full release readiness is not claimed. The previous prototype remains intact.

Update 22 September: OurNet is in everyday use on Windows and a physical Pixel 8
Pro, and ships to Google Play internal testing and the Microsoft Store. Recorded
physical-device checks: the Android document-provider acceptance test and the
history/editor profile journey ([PRIVATE_DRIVE.md](PRIVATE_DRIVE.md)), and
voice-note recording/transcription timing ([NOTES_KEEP.md](NOTES_KEEP.md)).
Android background sync, the stay-connected foreground service and the Windows
notification area are implemented ([CONNECTIVITY.md](CONNECTIVITY.md)). Rows
below are otherwise as of 9 September.

Update 10 September: OurNet 0.2 adds app-managed private folders/files, encrypted
offline copies, revision history, concurrent-edit resolution, deletion/restore,
and history re-encryption for new devices. Core tests cover revision convergence
and late enrolment; a real QUIC test covers automatic caching and offline export.
Discussion navigation and hardware Enter/Shift+Enter behaviour now have UI tests.
See PRIVATE_DRIVE.md and PERFORMANCE.md for the new workflows and measurements.

| Capability | New implementation | Validation so far |
|---|---|---|
| Persistent identity and independent device keys | Root-authorised device certificates; OS vault; separate local profiles | Core creation/restore/enrolment/revocation tests; Windows GUI launched by user |
| Friend contacts and live sync | Mutual local admission, real iroh QUIC, selective pages, adaptive retries | Local endpoint sync and stranger rejection tests |
| Provenance | Sender-signed handoffs, receiver-signed receipts, evidence-only reconciliation | Forgery, missing-path, multi-hop and convergence tests |
| Private messaging | Device envelopes, local sent history, delivery and read acknowledgements | Core and real QUIC tests; phone UI tests |
| Attachments | Encrypted chunked transfer, file picker, clipboard images, image viewer | Multi-chunk QUIC round trip, unauthorised friend refusal, corrupt blob refusal |
| Public files | On-demand download and sharing through admitted holders | Cached holder serves a file with its author offline in QUIC test |
| Forums | Subscriptions, posts, discussion/reply view, local read state | Post creation and navigation tests; multi-hop core sync tests |
| Locations | Offline world map, encrypted selected-recipient coordinates, expiry | Coordinate/expiry policy tests; rendered map and phone layout inspected |
| Voting and delegation | Typed signed objects; direct vote override; cycle-safe resolution | Delegation/cycle tests and phone layout |
| Profile and contact views | Signed names, identity/device enrolment, contact graph, blocking/revocation | Core policy tests and phone layout |
| Voice and video | WebRTC media with authenticated iroh signalling; ring, answer, mute, hang up | Loopback test with real camera/microphone (`calls_media_test.dart`); WAN calls need hands-on testing |
| Notifications and badges | Opt-in activity/call notifications, privacy-safe text, OS badge and sidebar counts | Compiles; OS delivery and action behaviour need hands-on testing |
| Appearance and responsive UI | Persistent theme, accent and compact spacing; phone drawer/desktop sidebar | All-page phone tests and rendered captures |
| Own node | UI-independent Dart transport and interactive password-encrypted CLI | CLI startup/publish/exit smoke check and pure Dart transport tests |
| Windows | Debug and release runner, independent profiles | Both builds passed; visible debug window confirmed by user |
| Android | Native transport, secure storage, file/media permissions | Everyday use and recorded acceptance/timing tests on a Pixel 8 Pro; Play internal testing builds |

## Still needed before declaring verified parity

- Two real devices: contact exchange, message/file/reply sync, app restart,
  notifications, microphone/camera and call cancellation.
- Internet/NAT traversal and offline/reconnect behaviour with changed addresses.
- Android file providers, permission refusal, notifications, background/resume,
  rotation, soft keyboard and real-device accessibility checks.
- Compare the new discussion and file workflows with the old UI in actual use;
  matching underlying actions does not establish equivalent usability.

## Broader foundation work

These are beyond the previous prototype's verified capabilities, but needed for
the intended long-lived application:

- Forward-secret messaging, reviewed protocol/cryptography, secure identity
  recovery, encrypted history transfer and a clear historical revocation policy.
- Storage retention/cleanup, larger datasets, resumable transfers, blind encrypted
  relay file serving and stronger per-peer CPU/bandwidth budgets.
- Configurable discovery/relay providers and platform-appropriate mobile wakeup.
- Battery/CPU/memory measurements on real hardware. Architectural improvements
  are implemented; measured gains have not yet been established.
- Packaging, update signatures, migrations, reproducible releases and deployment
  documentation. Linux/macOS scaffolding is not a validated platform port.
- Filesystem folder watching, wikis/web pages, routing/navigation and permissioned
  plugins. These were product goals, not completed old-prototype features.

## Repeatable checks

Run `tool/check.ps1` for core, transport and Flutter checks. Transport tests require
the verified native library installed by `tool/setup.ps1`. UI tests write local
QA captures to `app/build/qa` and use a real system font when available on Windows.
None of these automated tests proves production security or mobile battery life.
