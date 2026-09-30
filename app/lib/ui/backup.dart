import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../build_info.dart';
import '../services/session.dart';
import 'app.dart';
import 'onboarding.dart';

bool get _desktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

String _date(DateTime t) {
  final d = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// Saves everything in this profile to one zip: notes, messages, files and
/// contacts, with the keys sealed under a passphrase chosen here.
///
/// The work happens in the background behind a dialog of its own, so the rest
/// of the app stays usable. Returns whether a backup was saved.
Future<bool> saveBackup(BuildContext context, Node node) async {
  final name = 'ournet-backup-${_date(DateTime.now())}.zip';
  String? destination;
  if (_desktop) {
    // The backup can be large; write it straight to its folder rather than
    // handing the picker its bytes.
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose where to save your OurNet backup',
    );
    if (folder == null) return false;
    destination = '$folder${Platform.pathSeparator}$name';
    if (await File(destination).exists()) {
      if (!context.mounted) return false;
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Replace the existing backup?'),
          content: Text('$name is already in that folder.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (replace != true) return false;
    }
  } else {
    destination =
        '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}$name';
  }
  if (!context.mounted) return false;
  final target = destination;
  try {
    final info = await showDialog<BackupInfo>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PassphraseDialog<BackupInfo>(
        title: 'Protect your backup',
        explanation:
            'The backup holds your keys. Choose a passphrase of at least '
            '${Backup.minimumPassphrase} characters to seal them: you need it '
            'to restore, and OurNet cannot recover it for you.',
        confirm: true,
        action: 'Save backup',
        working: 'Saving your backup. You can keep using OurNet.',
        work: (passphrase) =>
            Backup.create(node, target, passphrase, appVersion: appVersion),
      ),
    );
    if (info == null) return false;
    if (!_desktop) {
      await SharePlus.instance.share(
        ShareParams(
          subject: 'OurNet backup',
          files: [XFile(target, mimeType: 'application/zip')],
        ),
      );
    }
    return true;
  } finally {
    // A phone keeps no copy of its own: the share sheet has the file by now.
    if (!_desktop) {
      final temp = File(target);
      if (await temp.exists()) await temp.delete();
    }
  }
}

/// Replaces this profile with a backup chosen by the person. [node] is the
/// profile now open; [replacing] says it holds data that will be lost.
/// [stopApp] stops whatever is using [node] once the app's screens are gone.
///
/// On success the app restarts itself on the restored profile. A backup that
/// cannot be opened changes nothing.
Future<void> restoreBackup(
  BuildContext context,
  Node node, {
  required bool replacing,
  Future<void> Function()? stopApp,
}) async {
  final picked = await FilePicker.pickFiles(
    dialogTitle: 'Choose your OurNet backup',
    type: FileType.custom,
    allowedExtensions: const ['zip'],
  );
  final path = picked.firstOrNull?.path;
  if (path == null || !context.mounted) return;
  final BackupInfo info;
  try {
    info = await Backup.inspect(path);
  } catch (e) {
    if (context.mounted) await _message(context, 'Cannot restore', '$e');
    return;
  }
  if (!context.mounted) return;
  if (info.version > Backup.version || info.schema > Store.schemaVersion) {
    await _message(
      context,
      'Cannot restore',
      'This backup was made by a newer OurNet. Update the app, then try again.',
    );
    return;
  }
  final staging = await restoreStagingPath();
  if (!context.mounted) return;
  final since = _date(info.created);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Restore this backup?'),
      content: Text(
        '${info.label.isEmpty ? 'A device' : info.label}, saved $since with '
        '${info.objects} items.\n\n'
        '${replacing ? 'Everything on this device is replaced by the backup: anything added since $since is lost here. ' : ''}'
        'Your friends and other devices catch this device up afterwards.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(replacing ? 'Replace everything' : 'Restore'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final staged = await showDialog<StagedRestore>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PassphraseDialog<StagedRestore>(
      title: 'Backup passphrase',
      explanation: 'Enter the passphrase you chose when saving this backup.',
      confirm: false,
      action: 'Restore',
      working: 'Opening your backup…',
      work: (passphrase) => Backup.stage(path, passphrase, staging),
    ),
  );
  if (staged == null) return;
  await _switchTo(staged, node, stopApp);
}

/// Stops the running app, swaps in the restored profile and starts it again.
Future<void> _switchTo(
  StagedRestore staged,
  Node node,
  Future<void> Function()? stopApp,
) async {
  final profile = activeProfile;
  runApp(const _Switching());
  // Let the old app dispose, so nothing still reads the store being closed.
  await WidgetsBinding.instance.endOfFrame;
  await stopApp?.call();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  try {
    final restored = await applyRestore(staged, node);
    runApp(OurNetApp(node: restored, initialTab: Destination.notes));
  } catch (e) {
    runApp(_RestoreFailed(error: '$e', profile: profile));
  }
}

Future<void> _message(BuildContext context, String title, String text) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );

/// Asks for a passphrase and runs [work] with it while the dialog shows
/// progress; a wrong passphrase or failure shows here and can be retried.
class PassphraseDialog<T> extends StatefulWidget {
  final String title, explanation, action, working;
  final bool confirm;
  final Future<T> Function(String passphrase) work;
  const PassphraseDialog({
    super.key,
    required this.title,
    required this.explanation,
    required this.action,
    required this.working,
    required this.confirm,
    required this.work,
  });
  @override
  State<PassphraseDialog<T>> createState() => _PassphraseDialogState<T>();
}

class _PassphraseDialogState<T> extends State<PassphraseDialog<T>> {
  final passphrase = TextEditingController(), repeat = TextEditingController();
  bool busy = false, hidden = true;
  String? error;

  Future<void> submit() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (widget.confirm) {
        SealedRoot.checkPhrase(passphrase.text);
        if (passphrase.text.trim() != repeat.text.trim()) {
          throw StateError('The two passphrases do not match');
        }
      }
      final result = await widget.work(passphrase.text);
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e is StateError ? e.message : '$e';
        });
      }
    }
  }

  @override
  void dispose() {
    passphrase.dispose();
    repeat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.explanation),
              const SizedBox(height: 12),
              TextField(
                controller: passphrase,
                enabled: !busy,
                autofocus: true,
                obscureText: hidden,
                decoration: InputDecoration(
                  labelText: 'Passphrase',
                  suffixIcon: IconButton(
                    tooltip: hidden ? 'Show' : 'Hide',
                    icon: Icon(
                      hidden ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () => setState(() => hidden = !hidden),
                  ),
                ),
                onSubmitted: (_) => widget.confirm ? null : submit(),
              ),
              if (widget.confirm)
                TextField(
                  controller: repeat,
                  enabled: !busy,
                  obscureText: hidden,
                  decoration: const InputDecoration(
                    labelText: 'Repeat passphrase',
                  ),
                  onSubmitted: (_) => submit(),
                ),
              if (busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(widget.working),
              ],
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy ? null : submit,
          child: Text(widget.action),
        ),
      ],
    ),
  );
}

class _Switching extends StatelessWidget {
  const _Switching();
  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Restoring your backup…'),
          ],
        ),
      ),
    ),
  );
}

class _RestoreFailed extends StatelessWidget {
  final String error, profile;
  const _RestoreFailed({required this.error, required this.profile});
  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'The backup could not be restored. Your previous profile is unchanged.',
              ),
              const SizedBox(height: 8),
              SelectableText(error),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  final node = await openNode(profile: profile);
                  runApp(
                    needsSetup ? SetupApp(node: node) : OurNetApp(node: node),
                  );
                },
                child: const Text('Back to OurNet'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
