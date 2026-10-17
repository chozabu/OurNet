import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';
import '../services/session.dart';

/// The root, unlocked for adding or removing a device, or null if the person
/// cancelled.
///
/// A device still holding its root in the clear seals it first, under a
/// phrase or none: either way it becomes a copy that can be given to other
/// devices. A copy sealed without a phrase opens without asking.
Future<SimpleKeyPair?> unlockRoot(BuildContext context, Node node) async {
  final identity = node.identity;
  if (!identity.holdsRoot) {
    throw StateError(
      'This device cannot add or remove devices. Use one of yours that can.',
    );
  }
  if (identity.sealedRoot != null && !identity.hasPhrase) {
    return identity.unlockRoot();
  }
  return showDialog<SimpleKeyPair>(
    context: context,
    barrierDismissible: false,
    builder: (_) => identity.root != null
        ? _NewPhraseDialog(node: node, mode: _NewPhrase.first)
        : _UnlockDialog(
            title: 'Recovery phrase',
            explanation: 'Enter your recovery phrase to add or remove devices.',
            open: (phrase) => identity.unlockRoot(phrase),
          ),
  );
}

/// Sets, changes or removes the recovery phrase on this device, which takes
/// it at once. This person's other devices are told, and each asks before it
/// switches. Returns whether the phrase changed.
Future<bool> changeRecoveryPhrase(BuildContext context, Node node) async {
  final identity = node.identity;
  if (!identity.holdsRoot) {
    throw StateError(
      'This device cannot change your recovery phrase. Use one of yours that can.',
    );
  }
  // The current phrase first: whoever holds an unlocked device must still
  // know it to replace it.
  final SimpleKeyPair? root;
  if (identity.hasPhrase) {
    root = await showDialog<SimpleKeyPair>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UnlockDialog(
        title: 'Current recovery phrase',
        explanation: 'Enter your current recovery phrase to change it.',
        open: (phrase) => identity.unlockRoot(phrase),
      ),
    );
  } else {
    root = await identity.unlockRoot();
  }
  if (root == null || !context.mounted) return false;
  final changed = await showDialog<SimpleKeyPair>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _NewPhraseDialog(node: node, mode: _NewPhrase.change, root: root),
  );
  return changed != null;
}

/// Asks to take [change], a phrase set on another of this person's devices.
/// This device keeps its own copy until the new phrase opens the new one, or
/// for good if the person keeps their current phrase.
Future<void> confirmRootChange(
  BuildContext context,
  Node node,
  RootCopy change,
) async {
  final where = change.device.label;
  final adopted = await showDialog<SimpleKeyPair>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UnlockDialog(
      title: 'Recovery phrase changed',
      explanation: change.copy.hasPhrase
          ? 'Your recovery phrase was changed on $where. Enter the new '
                'phrase to use it on this device too. Not you? Keep your '
                'current phrase and remove $where.'
          : 'Your recovery phrase was removed on $where. Use no phrase on '
                'this device too? Not you? Keep your current phrase and '
                'remove $where.',
      needsPhrase: change.copy.hasPhrase,
      action: change.copy.hasPhrase ? 'Use new phrase' : 'Remove phrase',
      decline: 'Keep current phrase',
      onDecline: () => node.declineRootChange(change),
      open: (phrase) async {
        final root = await change.copy.open(phrase);
        final next = await node.adoptRootChange(change);
        await saveIdentity(next);
        return root;
      },
    ),
  );
  if (adopted != null) node.notify();
}

/// A rough, local rating of [phrase] as it is typed: a warning, never a rule.
class PhraseStrengthMeter extends StatelessWidget {
  final String phrase;

  /// For a passphrase on a file that is copied around, such as a backup,
  /// where an empty one is worth a stronger word.
  final bool file;
  const PhraseStrengthMeter(this.phrase, {super.key, this.file = false});

  @override
  Widget build(BuildContext context) {
    final strength = PhraseStrength.of(phrase);
    final scheme = Theme.of(context).colorScheme;
    final (value, color) = switch (strength) {
      PhraseStrength.none => (0.0, scheme.error),
      PhraseStrength.weak => (0.33, scheme.error),
      PhraseStrength.fair => (0.66, Colors.orange),
      PhraseStrength.strong => (1.0, Colors.green),
    };
    final label = strength == PhraseStrength.none && file
        ? 'No passphrase: anyone who gets this file can open it'
        : strength.label;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            value: value,
            color: color,
            backgroundColor: scheme.surfaceContainerHighest,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// The recovery phrase in Settings: whether one is set, changing it, a
/// change made on another device, and devices still on another phrase.
class RecoveryPhraseCard extends StatefulWidget {
  final Node node;
  final String Function(DeviceCertificate) deviceLabel;
  const RecoveryPhraseCard({
    super.key,
    required this.node,
    required this.deviceLabel,
  });
  @override
  State<RecoveryPhraseCard> createState() => _RecoveryPhraseCardState();
}

class _RecoveryPhraseCardState extends State<RecoveryPhraseCard> {
  RootCopy? pending;
  List<DeviceCertificate> behind = const [];
  StreamSubscription<Set<String>>? changes;
  bool working = false;

  @override
  void initState() {
    super.initState();
    changes = widget.node.onChangesTo({Node.rootCopyKind}, load);
    load();
  }

  Future<void> load() async {
    final node = widget.node;
    final held = node.identity.sealedRoot;
    final copies = await node.rootCopies();
    final change = await node.pendingRootChange();
    if (!mounted) return;
    setState(() {
      pending = change;
      behind = [
        for (final c in copies.values)
          if (held != null && !held.same(c.copy)) c.device,
      ];
    });
  }

  Future<void> run(Future<void> Function() action) async {
    if (working) return;
    setState(() => working = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is StateError ? e.message : '$e')),
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
      await load();
    }
  }

  @override
  void dispose() {
    unawaited(changes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final identity = widget.node.identity;
    if (!identity.holdsRoot) return const SizedBox.shrink();
    final set = identity.hasPhrase;
    final change = pending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(set ? Icons.lock_outline : Icons.lock_open_outlined),
          title: Text(set ? 'Recovery phrase is set' : 'No recovery phrase'),
          subtitle: Text(
            set
                ? 'Needed to add or remove devices.'
                : 'Anyone holding one of your unlocked devices can add or '
                      'remove devices. Set a phrase for more protection.',
          ),
          trailing: TextButton(
            onPressed: working
                ? null
                : () => run(() async {
                    if (await changeRecoveryPhrase(context, widget.node) &&
                        context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Recovery phrase changed here. Confirm it on '
                            'your other devices.',
                          ),
                        ),
                      );
                    }
                  }),
            child: Text(set ? 'Change' : 'Set phrase'),
          ),
        ),
        if (change != null)
          Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.key_outlined),
              title: Text(
                'Recovery phrase changed on '
                '${widget.deviceLabel(change.device)}',
              ),
              subtitle: const Text(
                'This device still uses your previous phrase.',
              ),
              trailing: TextButton(
                onPressed: working
                    ? null
                    : () => run(
                        () => confirmRootChange(context, widget.node, change),
                      ),
                child: const Text('Review'),
              ),
            ),
          ),
        for (final device in behind.where(
          (d) => change == null || d.device != change.device.device,
        ))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.warning_amber_outlined),
            title: Text(
              '${widget.deviceLabel(device)} uses a different recovery '
              'phrase',
            ),
            subtitle: const Text(
              'Confirm the new phrase on that device, or change it there.',
            ),
          ),
      ],
    );
  }
}

enum _NewPhrase { first, change }

/// Choosing a phrase: the first one for a root still in the clear (which
/// may be skipped), or a new one for [root].
class _NewPhraseDialog extends StatefulWidget {
  final Node node;
  final _NewPhrase mode;
  final SimpleKeyPair? root;
  const _NewPhraseDialog({required this.node, required this.mode, this.root});
  @override
  State<_NewPhraseDialog> createState() => _NewPhraseDialogState();
}

class _NewPhraseDialogState extends State<_NewPhraseDialog> {
  final phrase = TextEditingController(), repeat = TextEditingController();
  bool busy = false, hidden = true;
  String? error;

  bool get first => widget.mode == _NewPhrase.first;

  Future<void> submit({bool skip = false}) async {
    if (busy) return;
    final text = skip ? '' : phrase.text;
    if (text.trim().isNotEmpty && text.trim() != repeat.text.trim()) {
      setState(() => error = 'The two phrases do not match');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final node = widget.node;
      final root = widget.root ?? node.identity.root!;
      final sealed = await node.identity.seal(text, unlocked: root);
      // The vault first: a copy this device cannot reopen after a restart
      // must never be the one it runs with or gives away.
      await saveIdentity(sealed);
      node.updateIdentity(sealed);
      // Other devices only have a copy to replace once one was shared.
      await node.announceRootCopy(changed: !first);
      if (mounted) Navigator.pop(context, root);
    } catch (e) {
      if (mounted) setState(() => error = e is StateError ? e.message : '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    phrase.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    phrase.dispose();
    repeat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final empty = phrase.text.trim().isEmpty;
    return AlertDialog(
      title: Text(first ? 'Set a recovery phrase' : 'New recovery phrase'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              first
                  ? 'Each of your devices can keep a copy of your identity, '
                        'locked by this phrase. With it, any of them can add '
                        'a new device or remove a lost one. Write it down '
                        'somewhere safe: nobody can recover it for you.\n\n'
                        'You can skip this: then anyone holding one of your '
                        'unlocked devices can add or remove devices. You can '
                        'set a phrase later in Settings.'
                  : 'This device uses the new phrase straight away. Your '
                        'other devices keep the old one until you confirm '
                        'the new one on each. Leave it empty for no phrase.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: phrase,
              autofocus: true,
              obscureText: hidden,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: 'Recovery phrase',
                helperText: 'A few unrelated words work well.',
                suffixIcon: IconButton(
                  tooltip: hidden ? 'Show phrase' : 'Hide phrase',
                  icon: Icon(hidden ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => hidden = !hidden),
                ),
              ),
            ),
            PhraseStrengthMeter(phrase.text),
            TextField(
              controller: repeat,
              obscureText: hidden,
              enabled: !busy && !empty,
              decoration: const InputDecoration(labelText: 'Repeat phrase'),
              onSubmitted: (_) => submit(),
            ),
            if (busy) ...[
              const SizedBox(height: 16),
              const Row(
                children: [
                  SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Locking your identity…'),
                ],
              ),
            ],
            if (error case final message?) ...[
              const SizedBox(height: 12),
              Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (first)
          TextButton(
            onPressed: busy ? null : () => submit(skip: true),
            child: const Text('Skip'),
          ),
        FilledButton(
          onPressed: busy || (first && empty) ? null : submit,
          child: Text(
            first
                ? 'Set phrase'
                : empty
                ? 'Remove phrase'
                : 'Change phrase',
          ),
        ),
      ],
    );
  }
}

/// Entering a phrase that [open] checks, returning what it opened.
class _UnlockDialog extends StatefulWidget {
  final String title, explanation, action;
  final bool needsPhrase;
  final String? decline;
  final void Function()? onDecline;
  final Future<SimpleKeyPair> Function(String phrase) open;
  const _UnlockDialog({
    required this.title,
    required this.explanation,
    required this.open,
    this.action = 'Unlock',
    this.needsPhrase = true,
    this.decline,
    this.onDecline,
  });
  @override
  State<_UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends State<_UnlockDialog> {
  final phrase = TextEditingController();
  bool busy = false, hidden = true;
  String? error;

  Future<void> submit() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final root = await widget.open(widget.needsPhrase ? phrase.text : '');
      if (mounted) Navigator.pop(context, root);
    } catch (e) {
      if (mounted) setState(() => error = e is StateError ? e.message : '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    phrase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.explanation),
          if (widget.needsPhrase) ...[
            const SizedBox(height: 16),
            TextField(
              controller: phrase,
              autofocus: true,
              obscureText: hidden,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: 'Recovery phrase',
                suffixIcon: IconButton(
                  tooltip: hidden ? 'Show phrase' : 'Hide phrase',
                  icon: Icon(hidden ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => hidden = !hidden),
                ),
              ),
              onSubmitted: (_) => submit(),
            ),
          ],
          if (busy) ...[
            const SizedBox(height: 16),
            const Row(
              children: [
                SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Text('Unlocking…'),
              ],
            ),
          ],
          if (error case final message?) ...[
            const SizedBox(height: 12),
            Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: Text(widget.decline == null ? 'Cancel' : 'Not now'),
      ),
      if (widget.decline case final decline?)
        TextButton(
          onPressed: busy
              ? null
              : () {
                  widget.onDecline?.call();
                  Navigator.pop(context);
                },
          child: Text(decline),
        ),
      FilledButton(onPressed: busy ? null : submit, child: Text(widget.action)),
    ],
  );
}
