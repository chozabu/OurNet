import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:rfw/rfw.dart';

class NetworkCommit {
  final String sha, repository, title, author;
  final int lane, at;
  final List<String> parents, labels;
  const NetworkCommit({
    required this.sha,
    required this.repository,
    required this.title,
    required this.author,
    required this.lane,
    required this.at,
    required this.parents,
    required this.labels,
  });
}

Widget commitNetworkWidget(BuildContext context, DataSource source) =>
    GitNetworkView(
      commits: [
        for (var i = 0; i < source.length(['nodes']); i++)
          NetworkCommit(
            sha: source.v<String>(['nodes', i, 'sha']) ?? '',
            repository: source.v<String>(['nodes', i, 'repo']) ?? '',
            title: source.v<String>(['nodes', i, 'title']) ?? '',
            author: source.v<String>(['nodes', i, 'author']) ?? '',
            lane: source.v<int>(['nodes', i, 'lane']) ?? 0,
            at: source.v<int>(['nodes', i, 'at']) ?? 0,
            parents: [
              for (var j = 0; j < source.length(['nodes', i, 'parents']); j++)
                source.v<String>(['nodes', i, 'parents', j]) ?? '',
            ],
            labels: [
              for (var j = 0; j < source.length(['nodes', i, 'labels']); j++)
                source.v<String>(['nodes', i, 'labels', j]) ?? '',
            ],
          ),
      ],
      lanes: [
        for (var i = 0; i < source.length(['lanes']); i++)
          source.v<String>(['lanes', i, 'name']) ?? '',
      ],
      onCommit: source.handler<void Function(NetworkCommit)>(
        ['onCommit'],
        (trigger) =>
            (commit) => trigger({'sha': commit.sha, 'repo': commit.repository}),
      ),
    );

/// A bounded commit window. Layout is computed once, and the painter only
/// visits the supplied page. Repository traversal belongs to the plugin worker.
class GitNetworkView extends StatelessWidget {
  final List<NetworkCommit> commits;
  final List<String> lanes;
  final ValueChanged<NetworkCommit>? onCommit;
  const GitNetworkView({
    super.key,
    required this.commits,
    required this.lanes,
    this.onCommit,
  });
  static const left = 220.0, top = 55.0, step = 36.0, row = 42.0;
  static const colors = [
    Colors.teal,
    Colors.blue,
    Colors.deepOrange,
    Colors.purple,
    Colors.pink,
    Colors.indigo,
    Colors.green,
    Colors.brown,
  ];
  @override
  Widget build(BuildContext context) {
    if (commits.isEmpty) {
      return const Center(child: Text('No commit graph available yet'));
    }
    final points = <String, Offset>{
      for (var i = 0; i < commits.length; i++)
        commits[i].sha: Offset(left + i * step, top + commits[i].lane * row),
    };
    final size = Size(
      math.max(700, left + commits.length * step + 48),
      math.max(300, top + lanes.length * row + 24),
    );
    final theme = Theme.of(context);
    return ClipRect(
      child: InteractiveViewer(
        constrained: false,
        minScale: 0.25,
        maxScale: 3,
        boundaryMargin: const EdgeInsets.all(32),
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _NetworkPainter(
                    commits,
                    points,
                    lanes,
                    theme.colorScheme.onSurface,
                    theme.colorScheme.outlineVariant,
                  ),
                ),
              ),
              for (final c in commits)
                Positioned(
                  left: points[c.sha]!.dx - 11,
                  top: points[c.sha]!.dy - 11,
                  child: Tooltip(
                    message:
                        '${c.title}\n${c.author}\n${c.sha}\n${c.labels.join('\n')}',
                    child: Semantics(
                      button: true,
                      label:
                          '${c.title}, ${c.sha.substring(0, math.min(7, c.sha.length))}',
                      child: InkResponse(
                        onTap: onCommit == null ? null : () => onCommit!(c),
                        radius: 16,
                        child: const SizedBox(width: 22, height: 22),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NetworkPainter extends CustomPainter {
  final List<NetworkCommit> commits;
  final Map<String, Offset> points;
  final List<String> lanes;
  final Color foreground, grid;
  _NetworkPainter(
    this.commits,
    this.points,
    this.lanes,
    this.foreground,
    this.grid,
  );
  void text(
    Canvas canvas,
    String value,
    Offset at, {
    double width = 190,
    double size = 12,
    Color? color,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: size,
          color: color ?? foreground,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: width);
    painter.paint(canvas, at);
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (var lane = 0; lane < lanes.length; lane++) {
      final y = GitNetworkView.top + lane * GitNetworkView.row;
      canvas.drawLine(
        Offset(GitNetworkView.left - 15, y),
        Offset(size.width, y),
        Paint()..color = grid.withValues(alpha: 0.3),
      );
      text(
        canvas,
        lanes[lane],
        Offset(8, y - 8),
        color: GitNetworkView.colors[lane % GitNetworkView.colors.length],
      );
    }
    for (var i = 0; i < commits.length; i++) {
      final c = commits[i];
      final from = points[c.sha]!;
      final color =
          GitNetworkView.colors[c.lane % GitNetworkView.colors.length];
      for (final parent in c.parents) {
        final to = points[parent] ?? Offset(size.width - 12, from.dy);
        final middle = (from.dx + to.dx) / 2;
        canvas.drawPath(
          Path()
            ..moveTo(from.dx, from.dy)
            ..cubicTo(middle, from.dy, middle, to.dy, to.dx, to.dy),
          Paint()
            ..color = color
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke,
        );
      }
      canvas.drawCircle(from, 5, Paint()..color = color);
      if (c.parents.length > 1) {
        canvas.drawCircle(
          from,
          8,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      if (i % 5 == 0 && c.at > 0) {
        final at = DateTime.fromMillisecondsSinceEpoch(c.at).toLocal();
        text(
          canvas,
          '${at.day}/${at.month}',
          Offset(from.dx - 15, 12),
          width: 80,
          size: 10,
        );
      }
      if (c.labels.isNotEmpty) {
        text(
          canvas,
          c.labels.length == 1 ? '●' : '● ${c.labels.length}',
          Offset(from.dx - 5, from.dy - 25),
          width: 45,
          size: 10,
          color: color,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_NetworkPainter old) =>
      old.commits != commits ||
      old.foreground != foreground ||
      old.grid != grid;
}
