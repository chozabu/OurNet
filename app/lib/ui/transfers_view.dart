import 'package:flutter/material.dart';
import 'package:ournet_transport/ournet_transport.dart'
    show Transfer, Transfers;

String _megabytes(int bytes) => bytes < 1024 * 1024 * 1024
    ? '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB'
    : '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';

/// Large files being stored or fetched, each with its progress and a way
/// to stop it. Redraws only itself as they move, never the page around it.
class TransfersView extends StatefulWidget {
  final Transfers transfers;
  const TransfersView({super.key, required this.transfers});

  @override
  State<TransfersView> createState() => _TransfersViewState();
}

class _TransfersViewState extends State<TransfersView> {
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.transfers.addListener(_changed);
  }

  @override
  void didUpdateWidget(TransfersView old) {
    super.didUpdateWidget(old);
    if (old.transfers != widget.transfers) {
      old.transfers.removeListener(_changed);
      widget.transfers.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.transfers.removeListener(_changed);
    super.dispose();
  }

  Widget _row(Transfer t) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(t.upload ? Icons.upload_file : Icons.download),
    title: Text(t.name, overflow: TextOverflow.ellipsis),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: t.total == 0 ? null : t.done / t.total,
        ),
        const SizedBox(height: 4),
        Text(
          t.cancelled
              ? 'Stopping…'
              : '${t.upload ? 'Adding' : 'Fetching'} · '
                    '${_megabytes(t.done)} of ${_megabytes(t.total)}',
        ),
      ],
    ),
    trailing: IconButton(
      tooltip: t.upload
          ? 'Stop (adding it again carries on from here)'
          : 'Stop (fetched parts are kept)',
      icon: const Icon(Icons.close),
      onPressed: t.cancelled ? null : t.cancel,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final active = widget.transfers.active;
    if (active.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final t in active) _row(t)],
    );
  }
}
