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
- Group owners can add/remove members; people added always see the group's
  history. An owner can let members add people too (on by default for new
  groups, and not turned off again): the people added get the group's key, so
  they open what came before and members pass it on to them without the owner
  online. Members can leave. Individual notes now have collaborator controls and Android widgets:
  see [Notes and widgets](NOTES.md). Existing private group/chat history is not migrated to
  devices enrolled after that history was encrypted. There is no invite-link
  service: friend invitations use the existing contact-card exchange.

## Validation

The following is the historical foundation record, not current widget validation.
See [Notes and widgets](NOTES.md) for the current implementation and checks.

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

## September 2026 updates

Implemented in September 2026.

15 September: [Voice notes and Keep parity](NOTES.md): recordings with
on-device transcription (also from the widgets), photos, drawings, archive,
labels, reminders, nested lists, formatting, undo/redo, selection, rearranging
and forward-compatible note fields.

14 September: [Individual shared notes and Android widgets](NOTES.md)
add a continuing note identity, field-level checklist operations, recoverable
text branches, collaborator controls, native snapshots and an offline tap outbox.
The older personal-note dialog/checklist descriptions below are historical.

14 September (later): Keep-style Notes. Notes has a card grid with search and
pinned notes. The editor autosaves, with Enter-to-add list items, drag reorder,
a checked-items section and shared colours. On Android there is an all-notes
**OurNet · Notes** board widget. Connecting is also simpler:
- Friend invitations appear immediately and renew themselves.
- Friends on the same Wi-Fi find each other without a QR code.
- Comparison codes are large.
- An open invitation can be approved from any screen.
- A new friend can start a shared note straight away.
- Joining a device searches nearby automatically.
Details are in [NOTES.md](NOTES.md).

- Expiring, single-use friend invitations. QR scanning on supported camera platforms or copied invitation text on any platform. Matching codes require approval on the inviter's device; identities and their private data remain separate. Existing contact cards still work.
- Owner-signed private-group membership epochs, member lists, invitations, removal, departure and owner closure. Sharing old history is explicit and defaults off for new members. Continuing members retain the audience restrictions of individual older items. Legacy groups migrate when their owner edits membership.
- Search across readable current Notes, group items, messages, forum posts and drive entries, with destination filters and source navigation.
- Notes filters for text, links, files, lists and pinned items; personal checklists use the same offline list operations as groups.
- Filename search and newest/name/size sorting. Source actions for attachments. Image previews in Notes, groups, messages, forums, file lists, search and drive history; tap to enlarge.
- Titled forum discussions with optional attachments. New forums have an owner-bound address, a description, shareable address and owner moderation. Legacy named forums still work. Hiding and blocking also work locally.
- Clearer unread highlighting and conversation read action. Sending statuses distinguish local saving, recipient acknowledgement and file availability; receiving an attachment record is not described as downloading the original.

### Behaviour to preserve

Membership is an offline replicated operation. A device cannot exclude someone based on an update it has not received. On receiving an epoch update, the current view uses that membership and old handles resolve to it before writing. Closure/removal does not erase downloaded copies. Owner devices should complete one membership edit at a time; simultaneous owner edits resolve deterministically to one epoch.

History copied into a new epoch is labelled as shared history and records the original author. Group file history must be cached by the owner before the UI commits a membership change so the copied attachments have an available source. Existing encrypted objects are retained; no database wipe is required. Use this version on all participating devices for the new membership controls.

Preview reads verify file chunks and decrypt into memory. Persistent file caching keeps the existing encrypted chunks. Images up to 8 MiB preview automatically when cached or connected; larger images require a tap. Decode errors and unavailable sources have fallback states. Previews do not fetch third-party image URLs embedded in text.

An owner-moderated forum uses a self-certifying address beginning with `forum2:`. A human-readable name is display metadata, not the authority for moderation. Existing short named forums retain their previous semantics.

### Validation

Core tests cover selective history across multiple membership edits, stale writers, leave/close, forged ownership, editable copied checklists and ordinary offline convergence. Transport tests cover independent friend identities, rejection/approval, invitation expiry, encrypted transfers and denied recipients. Widget tests cover navigation, discussion creation, personal checklists, membership editing, image rendering, scoped search, source navigation, drafts and phone/desktop layouts.

### Everyday polish — 12 September 2026

- Notes, group and conversation drafts are stored locally, encrypted for the
  current device. Writes are debounced by 400 ms and flushed on lifecycle changes
  and successful submission. Drafts are not sent to contacts or synced to other
  devices. An abrupt process termination can lose the last typing interval.
- Completing a send only clears the submitted draft; text entered during the
  operation and drafts in other conversations are preserved.
- Notes open in a scrollable, selectable reading dialog; copying remains available
  in the dialog and item menu. Removing an item offers Undo in its original group.
- Notes filters, groups and conversation lists have separate in-session scroll
  positions. These positions are not persisted across application restarts.
- Unchanged background sync passes no longer request a full UI refresh.

Validation: encrypted draft persistence and restoration races, app reopening,
reading and removal/undo have regression coverage in `app/test/drafts_test.dart`.
Physical Android lifecycle and Windows clipboard/file-picker acceptance remain
hands-on checks; this update does not change background delivery guarantees.
