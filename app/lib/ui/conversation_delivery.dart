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
    final status =
        error ??
        (active
            ? 'Checking delivery devices…'
            : !widget.network.running
            ? 'Saved here · networking is off'
            : delayed
            ? 'A delivery device is unavailable · automatic retry is scheduled'
            : 'Direct delivery needs an available recipient device');
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Expanded(
            child: Text(status, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          TextButton(
            onPressed: active ? null : retry,
            child: const Text('Retry delivery'),
          ),
          Tooltip(
            message:
                'A sleeping phone may not receive messages or calls until OurNet resumes. Without an online forwarding holder, your device must be online when the recipient connects.',
            child: const Icon(Icons.info_outline, size: 18),
          ),
        ],
      ),
    );
  }
}
