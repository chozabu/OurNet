# Everyday sharing

The default destination is **Notes**, with separate **Link my phone or PC** and
**Invite a friend** actions, and private groups.

## Try it

1. Link your phone and PC under the same identity. Leave OurNet open on both.
2. On Android, share text, a webpage, a photo, or documents to OurNet / My inbox.
   Both single and multiple file shares are accepted. Native imports run off the
   UI thread and stage files in internal app storage until publication succeeds.
3. On Windows, open My inbox and drop files, attach a file, or use the paste
   button for clipboard text or a screenshot. Save original exports the original
   file bytes and filename. The existing 64 MiB per-file limit applies.
4. Create a private group on Home, name it, and select known friends. Exchange
   contact cards in both directions first. Groups have Conversation, Files,
   and Lists; messages/files can be pinned. List names distinguish shopping,
   packing, and other checklists. Items can be checked, edited, or removed.

## Reliability and privacy

- Inbox and group records are encrypted signed objects in local SQLite. Existing
  transport retries replicate queued records while connected. Android resumes
  networking when reopened; suspended Android delivery is not promised.
- Each list item has its own operation history. Independent offline edits merge;
  concurrent edits to the same item converge by Lamport counter then object ID.
  Removed items remain in signed history, but are hidden from the current view.
- File downloads retry every 15 seconds while the app is connected. One failed
  item does not block the others. Errors are visible on the item.
- Delivery acknowledgements are published only after file chunks have been
  verified and cached. Metadata sync alone never means a file was delivered.
  “Available offline” refers to this device. A delivery label names a receiving
  device; it does not claim all devices received it.
- New-device enrollment can republish inbox and drive history to the new device.
- Group owners can add/remove members with explicit history sharing; members can
  leave. Individual notes now have collaborator controls and Android widgets:
  see [Notes and widgets](NOTES_WIDGETS.md). Existing private group/chat history is not migrated to
  devices enrolled after that history was encrypted. There is no invite-link
  service: friend invitations use the existing contact-card exchange.

## Validation

The following is the historical foundation record, not current widget validation.
See [Notes and widgets](NOTES_WIDGETS.md) for the current implementation and checks.

- Core suite: 16 passing tests, including offline group/list convergence, privacy
  from outsiders, malformed records, and inbox history for newly linked devices.
- Transport suite: 6 passing tests over real local QUIC endpoints.
- Flutter suite: 11 passing tests, including phone inbox saving, group checkboxes,
  keyboard layout, staged Android share retries, and a real two-device inbox
  transfer that exports identical original bytes offline after acknowledgement.
- Flutter analyzer clean. Android debug APK and Windows debug build succeed.
- Phone inbox capture: `app/build/qa/phone-inbox.png`.
- No Android device/emulator was connected: the native share sheet and physical
  desktop drag/clipboard interactions still need a hands-on acceptance pass.

Implementation references: [Android receive intents](https://developer.android.com/develop/ui/compose/sharing/receive)
and [desktop_drop](https://pub.dev/packages/desktop_drop).
