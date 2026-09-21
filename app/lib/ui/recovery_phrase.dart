import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';
import '../services/session.dart';

/// The root, unlocked for adding or removing a device, or null if the person
/// cancelled.
///
/// A device still holding its root in the clear seals it first. The phrase
/// is what makes a copy of the root safe to give to other devices, so it is
/// set before the root is ever used rather than when one is shared.
Future<SimpleKeyPair?> unlockRoot(BuildContext context, Node node) async {
  if (!node.identity.holdsRoot) {
    throw StateError(
      'This device cannot add or remove devices. Use one of yours that can.',
    );
  }
  return showDialog<SimpleKeyPair>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PhraseDialog(node: node),
  );
}

class _PhraseDialog extends StatefulWidget {
  final Node node;
  const _PhraseDialog({required this.node});
  @override
  State<_PhraseDialog> createState() => _PhraseDialogState();
}

class _PhraseDialogState extends State<_PhraseDialog> {
  final phrase = TextEditingController(), repeat = TextEditingController();
  late final creating = widget.node.identity.root != null;
  bool busy = false, hidden = true;
  String? error;

  Future<void> submit() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final node = widget.node;
      final SimpleKeyPair root;
      if (creating) {
        SealedRoot.checkPhrase(phrase.text);
        if (phrase.text.trim() != repeat.text.trim()) {
          throw StateError('The two phrases do not match');
        }
        root = node.identity.root!;
        final sealed = await node.identity.seal(phrase.text);
        // The vault first: a copy this device cannot reopen after a restart
        // must never be the one it runs with or gives away.
        await saveIdentity(sealed);
        node.updateIdentity(sealed);
      } else {
        root = await node.identity.unlockRoot(phrase.text);
      }
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
    repeat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(creating ? 'Set a recovery phrase' : 'Recovery phrase'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            creating
                ? 'Each of your devices keeps a copy of your identity, locked '
                      'by this phrase. With it, any of them can add a new '
                      'device or remove a lost one. Without it, nobody can, '
                      'including you, so write it down somewhere safe.\n\n'
                      'Use at least ${SealedRoot.minimumPhrase} characters. '
                      'A few unrelated words work well.'
                : 'Enter your recovery phrase to add or remove devices.',
          ),
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
            onSubmitted: creating ? null : (_) => submit(),
          ),
          if (creating)
            TextField(
              controller: repeat,
              obscureText: hidden,
              enabled: !busy,
              decoration: const InputDecoration(labelText: 'Repeat phrase'),
              onSubmitted: (_) => submit(),
            ),
          if (busy) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text(creating ? 'Locking your identity…' : 'Unlocking…'),
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
      FilledButton(
        onPressed: busy ? null : submit,
        child: Text(creating ? 'Set phrase' : 'Unlock'),
      ),
    ],
  );
}
