# Messaging and calls

## Direction

Prioritise reliability, ease of use and independence from mandatory servers.
Retain the current encryption; ratcheting and security redesign are deferred.
Groups are outside this phase. Initial platforms are Android and Windows.

Direct connections and local-network operation remain useful on their own.
Optional personal nodes or chosen helpers may retain messages for recipients
who are offline. Without an available holder, a sender that goes offline cannot
deliver to a recipient that comes online later. Media relays and mobile wakeup
also need explicit, replaceable infrastructure choices; they are not implemented
by the sync improvements below.

## Implemented: delivery scheduling

- Requests arriving during an active peer exchange coalesce into a follow-up,
  and callers await that follow-up instead of silently dropping the request.
- Automatic sync, manual refresh, retries and page continuation share a queue
  with at most two active peer exchanges and one queued request per device.
- Local changes batch from the first change within a 400 ms window. Continuous
  editing no longer indefinitely resets the delivery timer.
- Stopping networking clears the batch timer, allowing resume to schedule again.
- Existing persisted message objects remain the durable outgoing source; no
  second copy or separate in-memory-only outbox was introduced.

Regression tests cover coalescing, bounded concurrency, queue recovery after
failure, real QUIC delivery during an otherwise-final exchange, delivery during
continuous changes, and offline messages surviving a sender database restart.
The long-history integration journey now uses the same queue and batching
behaviour while editing and importing a photo.

## Remaining sequence

1. Conversation history and delivery UX: indexed per-conversation pagination,
   incremental latest/unread state, operation-specific errors and retry actions.
   Verify history beyond the existing shared 1,000-message query limit.
2. Attachment recovery: retained partial transfers, restart/resume, availability
   of originals and bounded background processing with usable navigation.
3. Availability: optional forwarding holders, device discovery and mobile
   wakeup. Explicitly distinguish local saving, helper acceptance and recipient
   acknowledgement. Keep direct-only operation usable.
4. Audio: ring a person across eligible devices, arbitrate a single answer,
   recover from connection changes, audio route controls, native incoming-call
   integration and optional TURN configuration that ordinary users can use.
5. Video and chat polish: camera controls, quality adaptation, voice messages,
   replies, reactions, edits and media navigation.

## Acceptance

Use temporary profiles and physical devices on separate networks. Exercise
restart, lock/sleep, permission denial, loss and return of connectivity, concurrent
edits/transfers, and long histories. Follow PERFORMANCE.md for timing runs.
Local QUIC tests establish application delivery behaviour, not WAN reachability,
mobile wakeup, call quality or battery performance. Do not claim those from builds.

### Validation of the scheduling increment

- Transport: all 19 tests passed; transport and Flutter app analysis passed.
- Windows profile long-history journey: passed with PERF_ENFORCE=true, including
  the documented p95/p99 frame and maximum event-loop-delay assertions.
- Fixture: 25 notes, 30 edits each, 825 objects. During photo import and editing,
  frame-stage p95 was 1.149 ms, p99 4.538 ms and maximum sampled event-loop delay
  11.526 ms. These are one-machine observations, not comparative speedup claims.
- Report: app/build/messaging-sync-note-history-windows.json (generated output).
- Physical Android timing, WAN delivery and actual voice/video remain untested
  in this increment. The full multi-journey performance suite was not run.

## Conversation history increment

- Added a derived per-person/per-peer SQLite routing index, backfilled for
  existing profiles and maintained transactionally by insert/delete triggers.
  It stores routing metadata only; message encryption and signed objects remain
  unchanged.
- Conversation history uses 50-message keyset pages, ordered by timestamp and
  object ID. Other conversations no longer consume a shared 1,000-message limit.
  Contact previews query the indexed latest message.
- Opened conversations retain their loaded pages. Coalesced refreshes consume
  newly inserted message records in bounded batches and merge them into loaded
  ranges, including late arrivals, without requerying all loaded history in builds.
- Text sending has per-conversation activity and save-error retry. It captures
  the recipient and draft before awaiting publication; other conversations remain
  usable. Existing encrypted drafts are reused.
- Mark-read is explicitly labelled as applying to loaded messages.

Unread counts now use transactional counters maintained as messages arrive,
are marked read/unread, expire or are deleted; blocked contacts are excluded.

### Further delivery and recovery work

- While reading older messages, incoming rows are deferred behind a bounded
  dirty flag and an explicit “Show latest messages” action. Loaded rows and the
  scroll offset stay unchanged during background sync. Choosing latest starts a
  fresh newest page; older pages remain available through pagination.
- Conversation-specific retry uses the existing shared sync scheduler. Failed
  peer exchanges are retained as per-device status and cleared on success.
  A local save, holder receipt and recipient receipt have distinct labels.
- File downloads expose progress and retry without taking the global busy state.
  Verified encrypted chunks survive failures and process restarts. Export partials
  are removed after failure; retries fetch missing chunks and rebuild the export.
  Original cache/export jobs have at most two active and sixteen outstanding jobs
  per node. The UI allows at most two concurrent file exports.
- Optional text forwarding selects an existing contact using the existing signed
  `via` field. Both parties must admit/connect to that helper. Helpers retain
  ciphertext and routing metadata, without message decryption keys. Linked devices
  of the sender already qualify as holders through the existing audience policy.
  New forwarding selections apply only to new text messages; attachment originals
  are not forwarded by this setting. Direct-only use remains the default.

Remaining: bounded retention across many opened conversations; recovery of an
interrupted local attachment import before its message was published; camera/paste
import actions still using shared busy state; automatic mobile wakeup; one-answer
call arbitration across devices, audio routing/recovery, native incoming-call
integration, video controls, voice messages, replies and reactions. No physical
Android device was connected. WAN and real audio/video remain unvalidated.

### Validation, 16 September 2026

- Package analysis passed for core, transport and app. Correctness tests passed:
  58 core, 23 transport and 47 app.
- All four Windows profile journeys passed with `PERF_ENFORCE=true`:
  responsiveness, photo scrolling, note history and conversation history.
- The new conversation journey starts with 1,005 messages, loads an older page,
  scrolls down, then receives 12 messages while typing. It verifies unchanged
  scroll position and draft, opens the latest page and sends the draft.
  The measured 2.4-second phase recorded 116 frames: frame-stage p95 8.938 ms,
  p99 10.596 ms, and maximum sampled event-loop delay 15.338 ms. Initial fixture
  creation and initial sync are outside that measured phase.
- Report: `app/build/conversation_history_test-windows.json`. Other profile
  reports use the same `<test>-windows.json` naming convention under app/build.
- The profile journey uses two local nodes and protocol sync in one process.
  Separate local QUIC tests cover failed exchange retry, restart with partial
  attachment chunks and encrypted helper delivery while the sender is offline.
  These results do not establish WAN, Android sleep/wakeup or call reliability.
