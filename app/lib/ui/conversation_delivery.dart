import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// Conversation-specific connectivity feedback; never takes the app busy lock.
class ConversationDelivery extends StatefulWidget {
  final PeerNetwork network;
  final String person;
  final List<String> helpers;
  const ConversationDelivery({
    super.key,
    required this.network,
    required this.person,
    this.helpers = const [],
  });
  @override
  State<ConversationDelivery> createState() => _ConversationDeliveryState();
}

class _ConversationDeliveryState extends State<ConversationDelivery> {
  StreamSubscription<void>? activity;
  bool retrying = false;
  String? error;

  @override
  void initState() {
    super.initState();
    activity = widget.network.syncActivity.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    activity?.cancel();
    super.dispose();
  }

  List<String> get devices => widget.network.node.contacts.values
      .where(
        (c) =>
            (c.person == widget.person ||
                widget.helpers.contains(c.person) ||
                c.person == widget.network.node.person) &&
            widget.network.node.allowedPeer(c.device),
      )
      .map((c) => c.device)
      .toList();

  Future<void> retry() async {
    if (retrying) return;
    setState(() {
      retrying = true;
      error = null;
    });
    try {
      final targets = devices;
      if (targets.isEmpty) {
        throw StateError(
          'No eligible recipient device. Add an updated contact card.',
        );
      }
      if (!widget.network.running) await widget.network.start();
      await Future.wait(targets.map(widget.network.sync));
    } catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    } finally {
      if (mounted) setState(() => retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final targets = devices;
    final delayed = targets.any(widget.network.syncErrors.containsKey);
    final active = retrying || targets.any(widget.network.syncing.containsKey);
    // Short header label; the tooltip carries the full explanation.
    final (status, detail) = error != null
        ? (error!, error!)
        : active
        ? ('Checking…', 'Checking delivery devices…')
        : !widget.network.running
        ? ('Offline', 'Saved here · networking is off')
        : delayed
        ? (
            'Retrying soon',
            'A delivery device is unavailable · automatic retry is scheduled',
          )
        : ('Encrypted', 'Direct delivery needs an available recipient device');
    final style = Theme.of(context).textTheme.bodySmall;
    return Row(
      children: [
        if (active)
          const Padding(
            padding: EdgeInsets.only(right: 6),
            child: SizedBox.square(
              dimension: 10,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
          ),
        Flexible(
          child: Tooltip(
            message:
                '$detail\n\nA sleeping phone may not receive messages or calls until OurNet resumes. Without an online forwarding holder, your device must be online when the recipient connects.',
            child: Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style?.copyWith(
                color: error != null
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Retry delivery',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 24),
          iconSize: 16,
          onPressed: active ? null : retry,
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }
}
