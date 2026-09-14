# Everyday features and sharing updates

Implemented in September 2026.

14 September: [Individual shared notes and Android widgets](NOTES_WIDGETS.md)
add a continuing note identity, field-level checklist operations, recoverable
text branches, collaborator controls, native snapshots and an offline tap outbox.
The older personal-note dialog/checklist descriptions below are historical.

- Expiring, single-use friend invitations. QR scanning on supported camera platforms or copied invitation text on any platform. Matching codes require approval on the inviter's device; identities and their private data remain separate. Existing contact cards still work.
- Owner-signed private-group membership epochs, member lists, invitations, removal, departure and owner closure. Sharing old history is explicit and defaults off for new members. Continuing members retain the audience restrictions of individual older items. Legacy groups migrate when their owner edits membership.
- Search across readable current Notes, group items, messages, forum posts and drive entries, with destination filters and source navigation.
- Notes filters for text, links, files, lists and pinned items; personal checklists use the same offline list operations as groups.
- Filename search and newest/name/size sorting. Source actions for attachments. Image previews in Notes, groups, messages, forums, file lists, search and drive history; tap to enlarge.
- Titled forum discussions with optional attachments. New forums have an owner-bound address, a description, shareable address and owner moderation. Legacy named forums still work. Hiding and blocking also work locally.
- Clearer unread highlighting and conversation read action. Sending statuses distinguish local saving, recipient acknowledgement and file availability; receiving an attachment record is not described as downloading the original.

## Behaviour to preserve

Membership is an offline replicated operation. A device cannot exclude someone based on an update it has not received. On receiving an epoch update, the current view uses that membership and old handles resolve to it before writing. Closure/removal does not erase downloaded copies. Owner devices should complete one membership edit at a time; simultaneous owner edits resolve deterministically to one epoch.

History copied into a new epoch is labelled as shared history and records the original author. Group file history must be cached by the owner before the UI commits a membership change so the copied attachments have an available source. Existing encrypted objects are retained; no database wipe is required. Use this version on all participating devices for the new membership controls.

Preview reads verify file chunks and decrypt into memory. Persistent file caching keeps the existing encrypted chunks. Images up to 8 MiB preview automatically when cached or connected; larger images require a tap. Decode errors and unavailable sources have fallback states. Previews do not fetch third-party image URLs embedded in text.

An owner-moderated forum uses a self-certifying address beginning with `forum2:`. A human-readable name is display metadata, not the authority for moderation. Existing short named forums retain their previous semantics.

## Validation

Core tests cover selective history across multiple membership edits, stale writers, leave/close, forged ownership, editable copied checklists and ordinary offline convergence. Transport tests cover independent friend identities, rejection/approval, invitation expiry, encrypted transfers and denied recipients. Widget tests cover navigation, discussion creation, personal checklists, membership editing, image rendering, scoped search, source navigation, drafts and phone/desktop layouts.

## Everyday polish — 12 September 2026

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
