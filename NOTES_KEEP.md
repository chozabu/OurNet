# Keep parity: voice notes, organisation and richer notes

Implemented 14–15 September 2026. Extends [NOTES_WIDGETS.md](NOTES_WIDGETS.md).

## Try the features

1. **Voice notes.** Tap the microphone in the Notes capture bar, press `v` on a
   desktop, or tap **🎤** on the **OurNet · Notes** board or **🎤 Voice** on the
   Quick capture widget. Recording starts at once and, with system speech, your
   words appear as you speak. Tap stop and the recorder turns straight into the
   new note, already holding the recording and its **Transcript** (under half
   a second on a Pixel 8 Pro, under 0.2 s on Windows). With Whisper the
   transcript fills in once transcription finishes. The audio stays in the note. Play, seek, transcribe
   again or remove it from the recording's menu. Edit the transcript like any
   other text; collaborators receive both.
2. **Transcription settings** (Settings → Voice note transcription):
   - **System speech** (Windows, and Android 13 and later): the operating
     system's recognizer writes the transcript **live while recording**, with no
     model download. The audio is still saved in the note. It is the default
     where that needs no new agreement: Android phones whose on-device
     recognizer has the language (audio stays on the phone; a missing language
     is downloaded in the background), and Windows when Online speech
     recognition is already on (Settings → Privacy & security → Speech; audio
     goes to Microsoft). On Android without on-device recognition, the first
     recording asks once, because the speech service may send audio to its
     provider. If live text fails part-way, the recording is transcribed
     afterwards (the system service on Android, Whisper on Windows if its model
     is downloaded). Windows dictation takes about a second to connect, so the
     recorder says *Starting…* until it listens.
   - **Whisper** (default elsewhere): runs inside OurNet after recording. Audio
     never leaves the device. The first transcription asks to download a model
     once: *Accurate* (60 MB) or *Fast* (32 MB), fetched from the whisper.cpp
     model repository and checked against a pinned SHA-256 before use.
   - **Off**: recordings are kept without text.
   - Spoken language: automatic or a fixed language.
3. **Add to a note** with **⊞** in the editor: take a photo (Android), add an
   image, draw, record, or show checkboxes. Photos and drawings appear at the
   top of the note; tap one to view, remove, or edit a drawing.
4. **Archive** with the archive button, a card's menu or by **swiping a card**
   (this replaces swipe-to-remove, as in Keep). Archived notes leave the main
   grid, stay searchable and are listed under **Archive**. Undo is offered.
5. **Labels.** Add them from a note's menu (**Add label**), a card's menu or the
   selection bar. Label chips above the grid filter notes; **Edit labels**
   renames or deletes them.
6. **Reminders.** The bell in the editor offers Later today, Tomorrow, Next week
   or a date, time and repeat (daily, weekly, monthly, yearly). **Reminders**
   lists notes soonest first. Notifications open the note.
7. **Lists:** **More → Uncheck all items / Delete checked items**. Nest an item
   with **Tab** (Shift+Tab to move it out) or the nesting button in the bottom
   bar. Checking a parent checks its nested items; dragging a parent moves them.
8. **Formatting** (text notes): the **Formatting** button in the bottom bar shows H1, H2, normal text,
   bold, italic, underline and clear formatting. Ctrl+B, Ctrl+I and Ctrl+U work
   on desktops.
9. **Undo and redo** for the whole note in the bottom bar (Ctrl+Z, Ctrl+Y or
   Ctrl+Shift+Z): typing, checks, nesting, order, removed items, colour and
   background.
10. **Select several notes** by long-pressing a card or with the check that
    appears on hover. The selection bar pins, sets reminders, colours, archives,
    labels, copies or removes them together.
11. **Rearrange** by long-pressing a card and dragging it onto another in the
    same section. Moved notes keep their position; new notes appear at the top.
12. **Removed** notes leave the Removed list after 7 days, or at once with
    **Empty Removed**. This hides them on your devices only; their encrypted
    history stays in local storage (no remote erasure) and restoring a note
    and removing it again shows it once more.
13. **Grab image text** (Android): in a photo's viewer, recognise its text on
    the device with ML Kit's bundled Latin-script model and add it to the note.
14. **Make a copy** and **Send** (the system share sheet, with photos) are in the
    editor's menu. **Backgrounds** (dots, grid, lined paper, waves, confetti,
    leaves) are with the colours.
15. **Keyboard shortcuts** on Notes: `c` new note, `l` new list, `v` voice
    note, `/` search, `Esc` clear selection, `e` archive, `f` pin, `Delete`
    remove, `Ctrl+A` select all.

## Model and compatibility

- **Forward compatibility.** `note_op` now accepts register names this build does
  not know (`name` or `name:<id>:name`, bounded values up to 8 KiB, text up to
  16,384 characters). Known registers keep their strict types. Future fields no
  longer make older builds reject a note's writing. Builds from before this
  change still reject the new registers below; update every participating
  device.
- New shared registers: `check:<id>:indent` (0 or 1), `format` (`markup`),
  `background`, `created` (an original creation time, for imports), and per
  attachment `file:<id>:meta` (kind `audio`/`image`/`drawing`, MIME type,
  duration or size; the encrypted chunk list and key travel in the same signed
  payload), `file:<id>:transcript`, `file:<id>:strokes` (a drawing's editable
  strokes as a second encrypted file), `file:<id>:order` and
  `file:<id>:deleted` (remove wins, recoverable).
- Attachments use the existing content-addressed, encrypted 128 KiB chunks and
  blob requests. A membership change republishes attachment heads with their
  chunk references, so new collaborators can fetch them. **Make a copy** reuses
  chunks rather than duplicating them. Up to 32 attachments, 64 MiB each.
- Formatting is lightweight markup inside the text register (`**bold**`,
  `*italic*`, `__underline__`, `# ` and `## ` headings), so concurrent text
  merges and recovery are unchanged. Builds without formatting show the markers.
- **Personal state** (`note_self` objects in space `_noteself`, encrypted to the
  person's own devices only): `pin`, `archive`, `labels`, `labelName`,
  `labelDeleted`, `reminder` (`{at, repeat}`), `order` (grid position) and
  `purged`. Registers name the versions they replace, so two of a person's
  devices converge. Collaborators never see them. Device-local pins from earlier
  builds migrate once. Each change is one signed object and counts toward the
  10,000-object quota.

## Voice notes: how it works

- Recording uses the `record` plugin: AAC in an MPEG-4 file (16 kHz mono,
  32 kbps on Android, about 240 KB a minute; 44.1 kHz on Windows, whose encoder
  requires it). Recordings stop after 30 minutes. The temporary file is deleted
  once it is encrypted into the note.
- Transcription (`app/plugins/ournet_speech`) decodes with the platform decoder
  (Android NDK MediaCodec, Windows Media Foundation), resamples to 16 kHz and runs
  whisper.cpp (vendored in `vendor/whisper_cpp`) on a background isolate with
  progress and cancellation. The decrypted recording exists as a temporary file
  only while decoding; leftovers are removed at start-up.
- Live system speech (`app/lib/services/live_speech.dart`, channel
  `ournet/speech`): on Windows the runner records the microphone itself
  (`windows/runner/voice_capture.cpp`, WASAPI into a Media Foundation AAC
  writer) while `system_speech.cpp` runs a WinRT continuous dictation session
  on the same microphone. The recorder plugin took about a second to stop and
  dictation's `StopAsync` over 1.5 s, which delayed each note by 2–3 s; now
  recording stops within a capture period, the words already recognised are
  used at once (waiting at most 1.5 s only for a phrase still being
  recognised), and the session closes in the background. A compiled
  recognizer is kept ready for the next recording, timeouts are raised for
  pauses, and sessions Windows ends on its own are restarted.
  On Android the recorder plugin cannot share the microphone with the
  recognizer, so `LiveSpeech.kt` captures it with `AudioRecord` at 48 kHz,
  encodes it to AAC (WAV if the encoder cannot be set up) and feeds 16 kHz
  samples through a pipe to `SpeechRecognizer` (`EXTRA_AUDIO_SOURCE`,
  segmented session), preferring the on-device recognizer with a full locale
  such as `en-GB` (bare codes are rejected). A recognizer that stops reading
  for 15 seconds is abandoned and the file is transcribed afterwards.
  Findings on a Pixel 8 Pro (Android 17): encoders must be configured with
  `CONFIGURE_FLAG_ENCODE`, and the speech service requires microphone
  permission even when reading a pipe.
- `integration_test/live_speech_test.dart` streams the speech sample through
  the Android pipe in real time to both recognizers, then presses the voice
  button and times Stop until the note is open with its transcript. Profile
  builds with 190 notes of history: 440 ms on the Pixel 8 Pro, 166 ms on
  Windows (where the microphone is recorded natively and dictation is only
  checked to start and stop).
- Jobs are durable settings: a transcription interrupted by closing the app
  resumes on the next start. Only the device that recorded a note transcribes
  it automatically, and an automatic transcript never replaces text someone has
  written. **Transcribe again** replaces it deliberately.
- Playback decrypts the recording into memory only while it plays.
- Like other Notes files, note attachments are cached in the background while
  OurNet is connected (an insertion cursor over note operations, no history
  rescans), so photos and recordings stay available offline.
- Measured with an 11-second sample (`integration_test/voice_note_test.dart`):
  Windows desktop, Fast model, 1.8 s; BV6600 Pro (Android 11), Fast 5.6 s,
  Accurate 10.7 s. Accurate is the default; it punctuated correctly.
- Android widgets open the app straight into the recorder. Recording in the
  background from a widget is not offered: Android restricts starting the
  microphone without a visible activity.

## Takeout readiness

Google Takeout exports one JSON file per Keep note. Import and export are a later
stage; the model now has a place for each field:

| Takeout field | OurNet |
|---|---|
| `title`, `textContent` | `title`, `text` |
| `textContentHtml` | `text` with `format: markup` (bold, italic, underline, headings) |
| `listContent[].text/isChecked` | `check:<id>:text`, `check:<id>:done`, order from position |
| nested list items | `check:<id>:indent` |
| `color` | `color` (palette names map to the nearest OurNet colour) |
| `isPinned`, `isArchived` | personal `pin`, `archive` |
| `isTrashed` | `deleted` |
| `labels[].name` | personal `labelName` + `labels` (matched by name, ignoring case) |
| `attachments[]` (images, drawings, audio) | `file:<id>:meta` with chunks; drawings import as images |
| `createdTimestampUsec` | `created` |
| `userEditedTimestampUsec` | not stored; edit times come from signed objects |
| `sharees[]` | not imported (collaborators must be OurNet friends) |
| `annotations[]` (web links) | kept in text; no link previews are fetched |

## Validation record — 15 September 2026

- `dart test` in `core`: 46 passed, including unknown-register tolerance,
  attachment chunks across a membership change and copies, personal state
  syncing between a person's own devices only, pin migration and emptying
  Removed per removal.
- `dart test` in `transport`: 12 passed (native library on `PATH`).
- `flutter test` in `app`: 40 passed. New: nesting, bulk uncheck/delete,
  note-level undo and redo of saved removals, formatting, labels, reminder and
  archive in the editor, voice-note transcripts, and the home screen's Archive,
  Reminders and label filters with bulk archive and Undo.
- `integration_test/voice_note_test.dart` on Windows (debug) and on the
  BV6600 Pro (`flutter drive --profile`): model download and SHA-256
  verification, AAC decoding, whisper.cpp transcription and saving the
  transcript to the note all passed.
- Android profile and Windows release builds succeed with the speech plugin.
- **Not yet checked by hand:** recording from the microphone and the new widget
  buttons on a phone (the test phone was locked), audio playback, drawing,
  camera capture, reminders firing, drag reordering on touch, and the Android
  13+ system speech option (no Android 13 device was available).
