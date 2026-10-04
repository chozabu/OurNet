import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/call_link.dart';
import '../services/group_calls.dart';

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

  String get _duration {
    final since = calls.joinedAt;
    if (since == null) return '';
    final s = DateTime.now().difference(since).inSeconds.clamp(0, 359999);
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
  }

  @override
  Widget build(BuildContext context) {
    final people = calls.participants;
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff137d72),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    );
    final mobile = DeviceMedia.mobile;
    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: const Color(0xff0e1214),
        body: SafeArea(
          child: Column(
            children: [
              _topBar(context, people.length),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: people.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : _grid(people),
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

  Widget _grid(List<CallParticipant> people) => LayoutBuilder(
    builder: (context, box) {
      final n = people.length;
      final wide = box.maxWidth > box.maxHeight;
      final columns = n <= 1
          ? 1
          : n == 2
          ? (wide ? 2 : 1)
          : n <= 4
          ? 2
          : n <= 6
          ? (wide ? 3 : 2)
          : (wide ? 4 : 3);
      final rows = (n / columns).ceil();
      const gap = 8.0;
      final w = (box.maxWidth - gap * (columns - 1)) / columns;
      final h = (box.maxHeight - gap * (rows - 1)) / rows;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        alignment: WrapAlignment.center,
        runAlignment: WrapAlignment.center,
        children: [
          for (final p in people)
            SizedBox(
              width: max(1, w - .01),
              height: max(1, h),
              child: _Tile(
                key: ValueKey(p.device),
                participant: p,
                label: widget.label(p),
              ),
            ),
        ],
      );
    },
  );

  Widget _controls(BuildContext context, bool mobile) {
    final scheme = Theme.of(context).colorScheme;
    Widget round({
      required IconData icon,
      required String tooltip,
      required VoidCallback? onPressed,
      bool on = false,
      Color? background,
      Color? foreground,
    }) => IconButton.filled(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 26,
      style: IconButton.styleFrom(
        minimumSize: const Size(56, 56),
        backgroundColor:
            background ?? (on ? Colors.white : scheme.surfaceContainerHighest),
        foregroundColor: foreground ?? (on ? Colors.black87 : Colors.white),
      ),
      icon: Icon(icon),
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

  Future<void> _devices(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: calls,
      builder: (context, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (calls.audioInputs.isNotEmpty)
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Microphone'),
                  initialValue: calls.audioInput,
                  items: [
                    for (final d in calls.audioInputs)
                      DropdownMenuItem(
                        value: d.deviceId,
                        child: Text(d.label.isEmpty ? d.deviceId : d.label),
                      ),
                  ],
                  onChanged: (id) {
                    if (id != null) {
                      widget.act(() => calls.selectAudioInput(id));
                    }
                  },
                ),
              const SizedBox(height: 12),
              if (calls.audioOutputs.isNotEmpty)
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Speakers'),
                  initialValue: calls.audioOutput,
                  items: [
                    for (final d in calls.audioOutputs)
                      DropdownMenuItem(
                        value: d.deviceId,
                        child: Text(d.label.isEmpty ? d.deviceId : d.label),
                      ),
                  ],
                  onChanged: (id) {
                    if (id != null) {
                      widget.act(() => calls.selectAudioOutput(id));
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Tile extends StatelessWidget {
  final CallParticipant participant;
  final String label;
  const _Tile({super.key, required this.participant, required this.label});

  static const _palette = [
    Color(0xff137d72),
    Color(0xff5c6bc0),
    Color(0xffc2185b),
    Color(0xffef6c00),
    Color(0xff6a1b9a),
    Color(0xff2e7d32),
    Color(0xff0277bd),
    Color(0xff8d6e63),
  ];

  @override
  Widget build(BuildContext context) {
    final p = participant;
    final showVideo =
        p.video &&
        p.renderer != null &&
        (p.self || p.link == LinkState.connected);
    final colour = _palette[p.person.hashCode.abs() % _palette.length];
    final initial = label.trim().isEmpty ? '?' : label.trim()[0].toUpperCase();
    final status = switch (p.link) {
      LinkState.connecting => 'Connecting…',
      LinkState.reconnecting => 'Reconnecting…',
      LinkState.failed => 'Cannot connect',
      _ => null,
    };
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
              RTCVideoView(
                p.renderer!,
                mirror: p.self,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              )
            else
              Center(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final size = min(
                      96.0,
                      min(box.maxWidth, box.maxHeight) * .5,
                    );
                    return Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        color: colour,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        initial,
                        style: TextStyle(
                          fontSize: size * .45,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (status != null)
              Positioned(
                top: 8,
                right: 8,
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
                      if (p.link != LinkState.failed) const SizedBox(width: 6),
                      Text(status, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ),
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (p.muted) ...[
                      const Icon(Icons.mic_off, size: 14, color: Colors.white),
                      const SizedBox(width: 4),
                    ],
                    Text(label, style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
