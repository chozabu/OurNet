# Try private drive between your devices

OurNet 0.2 adds an app-managed private drive. Files and folders are encrypted for
devices enrolled under the same person identity. This is not yet a watcher that
mirrors arbitrary folders elsewhere on your PC. Import, replace and export files
through OurNet; drive metadata then syncs automatically while connected.

## Pair two profiles or devices

1. Keep Alice as the owner. Start a **fresh** second profile, for example
   `tool/run.ps1 -Profile alice-phone`. Your existing Bob profile remains a
   different person and is not part of Alice's private drive.
2. On Alice, open Profile → **Add device**.
3. On the fresh device, choose **Connect to my existing profile** and scan the
   QR code, find Alice nearby, or paste Alice's invitation.
4. Compare the code on both screens and approve on Alice. Contact exchange is
   automatic. Their person IDs match while device IDs differ. The root secret
   remains on Alice. Leave **Share existing drive history** enabled to share old files.
5. Open Files → Private drive. Create a folder and add a small file on Alice.
   The other device should see the entry after sync. Enable **Keep files offline
   on this device** there to download an encrypted copy automatically.
6. Disconnect Alice. On the second device, choose the file's menu → Export file
   and compare it with the original. A downloaded copy works offline.

If you created files before enrolling the second device, use **Share history with
new devices** on a device that can already read them. This re-encrypts manifests
for the known device certificates, preserving revision identities and ancestry.
It applies to drive history; old private chat history still has no migration UI.

## Revisions and conflicts

- Upload new version replaces a logical file while keeping earlier revisions.
- Rename and Move create revisions; folders and metadata sync across devices.
- Offline edits to the same entry create concurrent versions. Neither is silently
  discarded. Open Version history, export either version, and choose **Use this
  version** to create a revision resolving the currently known conflict.
- History & deleted items lets you restore old versions or deleted entries.
- Delete removes an entry from the live drive, not its retained history or
  previously exported copies. Non-empty folders must be emptied first.
- New files with the same name are separate entries. Names are not file IDs.

The current limits remain 64 MiB per file, 512 MiB of stored chunks and 10,000
signed objects. History resharing consumes additional objects. Cleanup/retention,
filesystem watching, large transfers and background Android delivery remain work.
Use your own test files first; the protocol and recovery model are still evolving.
