import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../services/call_link.dart';
import '../services/group_calls.dart';
import 'call_widgets.dart';

/// "3 in call" and a way in, for a group whose call is going. Nobody is rung:
/// the call is just there, as a voice channel is, and anyone in the group can
/// join it. Shows nothing when no call is going.
class GroupCallBanner extends StatelessWidget {
  final GroupCalls calls;
  final String space;
  final String Function(CallMember) label;
  final VoidCallback onJoin;
  final VoidCallback onJoinVideo;
  final VoidCallback onOpen;
  const GroupCallBanner({
    super.key,
    required this.calls,
    required this.space,
    required this.label,
    required this.onJoin,
    required this.onJoinVideo,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final info = calls.infoFor(space);
    if (info == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final inIt = calls.inCall(space);
    final names = [for (final m in info.ordered) label(m)];
    final shown = names.take(3).join(', ');
    final more = names.length > 3 ? ' and ${names.length - 3} more' : '';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: inIt ? onOpen : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Row(
              children: [
                _LiveDot(color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        inIt
                            ? 'You are in this call · ${_count(info)}'
                            : 'Call in progress · ${_count(info)}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '$shown$more',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (inIt)
                  FilledButton.tonalIcon(
                    onPressed: onOpen,
                    icon: const Icon(Icons.open_in_full, size: 18),
                    label: const Text('Open'),
                  )
                else ...[
                  IconButton(
                    tooltip: 'Join with video',
                    onPressed: calls.active ? null : onJoinVideo,
                    icon: const Icon(Icons.videocam_outlined),
                  ),
                  FilledButton.icon(
                    onPressed: calls.active ? null : onJoin,
                    icon: const Icon(Icons.call, size: 18),
                    label: const Text('Join'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _count(CallInfo info) {
    final n = info.people.length;
    return n == 1 ? '1 person' : '$n people';
  }
}

/// A small "in call" marker for a list of groups.
class GroupCallChip extends StatelessWidget {
  final int people;
  const GroupCallChip({super.key, required this.people});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '$people in a call',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq, size: 15, color: scheme.primary),
            const SizedBox(width: 4),
            Text(
              '$people',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: scheme.onSecondaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveDot extends StatefulWidget {
  final Color color;
  const _LiveDot({required this.color});
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(begin: .35, end: 1).animate(_pulse),
    child: Icon(Icons.graphic_eq, color: widget.color),
  );
}

/// The bar shown over the app while in a call with the call screen closed.
class GroupCallBar extends StatelessWidget {
  final GroupCalls calls;
  final String title;
  final VoidCallback onOpen;
  final VoidCallback onLeave;
  const GroupCallBar({
    super.key,
    required this.calls,
    required this.title,
    required this.onOpen,
    required this.onLeave,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final info = calls.infoFor(calls.space ?? '');
    return Material(
      color: scheme.primaryContainer,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          child: Row(
            children: [
              _LiveDot(color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  calls.phase == 'joining'
                      ? 'Joining $title…'
                      : '$title · ${info?.people.length ?? 1} in call',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: calls.muted ? 'Unmute' : 'Mute',
                onPressed: calls.toggleMute,
                icon: Icon(calls.muted ? Icons.mic_off : Icons.mic),
              ),
              IconButton(
                tooltip: 'Leave call',
                onPressed: onLeave,
                icon: const Icon(Icons.call_end, color: Colors.red),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The call itself: everyone in it as a tile, the people speaking lit, and
/// the few controls a call needs.
class GroupCallScreen extends StatefulWidget {
  final GroupCalls calls;
  final String title;
  final String Function(CallParticipant) label;
  final Future<void> Function(Future<void> Function()) act;
  const GroupCallScreen({
    super.key,
    required this.calls,
    required this.title,
    required this.label,
    required this.act,
  });

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  Timer? _clock;
  bool _closing = false;

  /// The device shown large, picked by tapping its tile.
  String? _pinned;

  GroupCalls get calls => widget.calls;

  @override
  void initState() {
    super.initState();
    calls.addListener(_changed);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    calls.removeListener(_changed);
    _clock?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (!calls.active && !_closing) {
      _closing = true;
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
  }

  String get _duration => callDuration(calls.joinedAt);

  @override
  Widget build(BuildContext context) {
    final people = calls.participants;
    final theme = callTheme();
    final mobile = DeviceMedia.mobile;
    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: callBackground,
        body: SafeArea(
          child: Column(
            children: [
              _topBar(context, people.length),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: people.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : _stage(people),
                ),
              ),
              if (calls.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    calls.error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              _controls(context, mobile),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context, int count) {
    final quality = calls.quality;
    final (icon, color, text) = switch (quality) {
      CallQuality.good => (
        Icons.signal_cellular_alt,
        Colors.greenAccent,
        'Good connection',
      ),
      CallQuality.fair => (
        Icons.signal_cellular_alt_2_bar,
        Colors.amberAccent,
        'Connection is slow',
      ),
      CallQuality.poor => (
        Icons.signal_cellular_alt_1_bar,
        Colors.redAccent,
        'Poor connection',
      ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back to the app (the call carries on)',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.expand_more),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  calls.phase == 'joining'
                      ? 'Joining…'
                      : '$_duration · $count in call',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
          if (calls.phase == 'active')
            Tooltip(
              message: text,
              child: Icon(icon, color: color, size: 22),
            ),
        ],
      ),
    );
  }

  /// Tapping a tile pins that person large; tapping again unpins.
  Widget _tile(CallParticipant p, {bool small = false, bool whole = false}) =>
      GestureDetector(
        onTap: () =>
            setState(() => _pinned = _pinned == p.device ? null : p.device),
        child: _Tile(
          key: ValueKey(p.device),
          participant: p,
          label: widget.label(p),
          small: small,
          whole: whole,
        ),
      );

  /// Everyone fitted to the screen. With two, the other person fills it and
  /// you float in a corner; with someone pinned, they fill it and everyone
  /// else runs along a strip.
  Widget _stage(List<CallParticipant> people) => LayoutBuilder(
    builder: (context, box) {
      final pinned = people.where((p) => p.device == _pinned).firstOrNull;
      if (pinned != null && people.length > 1) {
        return _spotlight(pinned, people, box.biggest);
      }
      final self = people.where((p) => p.self).firstOrNull;
      if (people.length == 2 && self != null) {
        final other = people.firstWhere((p) => !p.self);
        return Stack(
          fit: StackFit.expand,
          children: [
            _tile(other, whole: !DeviceMedia.mobile),
            FloatingView(child: _tile(self, small: true)),
          ],
        );
      }
      return _grid(people, box.biggest);
    },
  );

  Widget _grid(List<CallParticipant> people, Size box) {
    const gap = 8.0;
    final (columns, tile) = gridFor(people.length, box, gap: gap);
    return Center(
      child: Wrap(
        spacing: gap,
        runSpacing: gap,
        alignment: WrapAlignment.center,
        runAlignment: WrapAlignment.center,
        children: [
          for (final p in people)
            SizedBox(
              width: max(1, tile.width - .01),
              height: max(1, tile.height),
              child: _tile(p, small: columns > 2),
            ),
        ],
      ),
    );
  }

  Widget _spotlight(
    CallParticipant pinned,
    List<CallParticipant> people,
    Size box,
  ) {
    final others = [
      for (final p in people)
        if (p.device != pinned.device) p,
    ];
    final wide = box.width > box.height * 1.2;
    const gap = 8.0;
    // Thumbnails beside the pinned person (landscape) or below (portrait).
    final side = wide
        ? (box.width * .18).clamp(110.0, 220.0)
        : (box.height * .14).clamp(80.0, 140.0);
    final thumb = wide ? Size(side, side * 3 / 4) : Size(side * 4 / 3, side);
    final strip = ListView.separated(
      scrollDirection: wide ? Axis.vertical : Axis.horizontal,
      itemCount: others.length,
      separatorBuilder: (_, _) => const SizedBox.square(dimension: gap),
      itemBuilder: (_, i) => SizedBox(
        width: thumb.width,
        height: thumb.height,
        child: _tile(others[i], small: true),
      ),
    );
    final main = _tile(pinned, whole: true);
    return wide
        ? Row(
            children: [
              Expanded(child: main),
              const SizedBox(width: gap),
              SizedBox(width: thumb.width, child: strip),
            ],
          )
        : Column(
            children: [
              Expanded(child: main),
              const SizedBox(height: gap),
              SizedBox(height: thumb.height, child: strip),
            ],
          );
  }

  Widget _controls(BuildContext context, bool mobile) {
    Widget round({
      required IconData icon,
      required String tooltip,
      required VoidCallback? onPressed,
      bool on = false,
      Color? background,
      Color? foreground,
    }) => CallButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: onPressed,
      on: on,
      background: background,
      foreground: foreground,
    );
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 14,
      runSpacing: 10,
      children: [
        round(
          icon: calls.muted ? Icons.mic_off : Icons.mic,
          tooltip: calls.muted ? 'Unmute' : 'Mute',
          on: calls.muted,
          onPressed: calls.toggleMute,
        ),
        round(
          icon: calls.camera ? Icons.videocam : Icons.videocam_off,
          tooltip: calls.camera ? 'Turn camera off' : 'Turn camera on',
          on: calls.camera,
          onPressed: calls.phase == 'active'
              ? () => widget.act(() => calls.toggleCamera())
              : null,
        ),
        if (mobile && calls.camera)
          round(
            icon: Icons.cameraswitch_outlined,
            tooltip: 'Switch camera',
            onPressed: () => widget.act(calls.switchCamera),
          ),
        if (mobile)
          round(
            icon: calls.speaker ? Icons.volume_up : Icons.hearing,
            tooltip: calls.speaker ? 'Speaker on' : 'Speaker off',
            on: calls.speaker,
            onPressed: () => widget.act(calls.toggleSpeaker),
          )
        else if (calls.audioInputs.isNotEmpty || calls.audioOutputs.isNotEmpty)
          round(
            icon: Icons.tune,
            tooltip: 'Microphone and speakers',
            onPressed: () => _devices(context),
          ),
        round(
          icon: Icons.call_end,
          tooltip: 'Leave call',
          background: Colors.red.shade600,
          foreground: Colors.white,
          onPressed: () => widget.act(calls.leave),
        ),
      ],
    );
  }

  Future<void> _devices(BuildContext context) => showCallDevices(
    context,
    listenable: calls,
    inputs: () => calls.audioInputs,
    outputs: () => calls.audioOutputs,
    input: () => calls.audioInput,
    output: () => calls.audioOutput,
    selectInput: (id) => widget.act(() => calls.selectAudioInput(id)),
    selectOutput: (id) => widget.act(() => calls.selectAudioOutput(id)),
  );
}

/// Columns, and the size of each tile, that show [count] tiles of a call as
/// large as they can be in [box]. Tiles stay between portrait 3:4 and
/// widescreen 16:9, so nobody is shown as a sliver.
(int, Size) gridFor(int count, Size box, {double gap = 8}) {
  var best = (1, Size.zero);
  var bestArea = -1.0;
  for (var columns = 1; columns <= max(1, count); columns++) {
    final rows = (count / columns).ceil();
    var w = (box.width - gap * (columns - 1)) / columns;
    var h = (box.height - gap * (rows - 1)) / rows;
    if (w <= 0 || h <= 0) continue;
    if (w / h > 16 / 9) w = h * 16 / 9;
    if (w / h < 3 / 4) h = w * 4 / 3;
    if (w * h > bestArea + .5) {
      bestArea = w * h;
      best = (columns, Size(w, h));
    }
  }
  return best;
}

class _Tile extends StatelessWidget {
  final CallParticipant participant;
  final String label;

  /// A thumbnail: a smaller name and status.
  final bool small;

  /// Shows the whole picture rather than filling the tile.
  final bool whole;
  const _Tile({
    super.key,
    required this.participant,
    required this.label,
    this.small = false,
    this.whole = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = participant;
    final showVideo =
        p.video &&
        p.renderer != null &&
        (p.self || p.link == LinkState.connected);
    final status = switch (p.link) {
      LinkState.connecting => 'Connecting…',
      LinkState.reconnecting => 'Reconnecting…',
      LinkState.failed => 'Cannot connect',
      _ => null,
    };
    final inset = small ? 4.0 : 8.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: const Color(0xff1b2226),
        border: Border.all(
          color: p.speaking ? Colors.greenAccent : Colors.transparent,
          width: 3,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (showVideo)
              CallVideo(p.renderer!, mirror: p.self, whole: whole)
            else
              Center(
                child: LayoutBuilder(
                  builder: (context, box) => CallAvatar(
                    label: label,
                    seed: p.person,
                    size: min(96.0, min(box.maxWidth, box.maxHeight) * .5),
                  ),
                ),
              ),
            if (status != null)
              Positioned(
                top: inset,
                right: inset,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (p.link != LinkState.failed)
                        const SizedBox.square(
                          dimension: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      if (p.link != LinkState.failed && !small)
                        const SizedBox(width: 6),
                      if (!small)
                        Text(status, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ),
            Positioned(
              left: inset,
              right: inset,
              bottom: inset,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (p.muted) ...[
                        const Icon(
                          Icons.mic_off,
                          size: 14,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: small ? 12 : 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
