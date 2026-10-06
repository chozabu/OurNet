import 'dart:async';
import 'package:flutter/material.dart';
import '../services/call_link.dart';
import '../services/calls.dart';
import 'package:ournet_core/ournet_core.dart' show Avatar;
import 'call_widgets.dart';

/// A one-to-one call, full screen: who it is with and where it has got to
/// while it rings, their video filling the screen once connected (yours
/// floating in a corner), and the controls a call needs. Closes itself when
/// the call ends; closing it early leaves the call going behind the app.
class CallScreen extends StatefulWidget {
  final Calls calls;

  /// Who the call is with.
  final String name;

  /// Picks their avatar colour.
  final Object? seed;

  /// The other person's profile picture, if they have one.
  final Avatar? avatar;
  final Future<void> Function(Future<void> Function()) act;
  const CallScreen({
    super.key,
    required this.calls,
    required this.name,
    required this.act,
    this.seed,
    this.avatar,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Timer? _clock;
  bool _closing = false;

  /// Controls and names over a connected video call; tapping toggles them.
  bool _chrome = true;

  Calls get calls => widget.calls;

  @override
  void initState() {
    super.initState();
    calls.addListener(_changed);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && calls.connectedAt != null) setState(() {});
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
    if (calls.phase == 'idle' && !_closing) {
      _closing = true;
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
  }

  bool get _live => calls.phase == 'connected' || calls.phase == 'reconnecting';

  /// What the other side has said it is doing: "Muted", "Camera off".
  String get _theirState => [
    if (calls.remoteMuted) 'Muted',
    if (calls.video && calls.remoteCameraOff) 'Camera off',
  ].join(' · ');

  String get _status => switch (calls.phase) {
    'ringing' => calls.video ? 'Incoming video call' : 'Incoming call',
    'calling' => calls.rung ? 'Ringing…' : 'Calling…',
    'connecting' => 'Connecting…',
    'reconnecting' => 'Reconnecting…',
    'connected' => callDuration(calls.connectedAt),
    'ending' => 'Call ended',
    'failed' => 'Connection lost',
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    final mobile = DeviceMedia.mobile;
    final remoteVideo =
        calls.video &&
        _live &&
        !calls.remoteCameraOff &&
        calls.remote.srcObject != null;
    final localVideo =
        calls.video && !calls.cameraOff && calls.local.srcObject != null;
    final mirror = !mobile || calls.frontCamera;
    final showChrome = _chrome || !remoteVideo;
    return Theme(
      data: callTheme(),
      child: Scaffold(
        backgroundColor: callBackground,
        body: LayoutBuilder(
          builder: (context, box) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: remoteVideo
                ? () => setState(() => _chrome = !_chrome)
                : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (remoteVideo)
                  CallVideo(calls.remote, whole: !mobile)
                else if (localVideo && !_live)
                  // Before they answer, you see yourself, as in a mirror.
                  Opacity(
                    opacity: .55,
                    child: CallVideo(calls.local, mirror: mirror),
                  ),
                if (!remoteVideo) _who(context),
                if (_live && localVideo)
                  Positioned.fill(
                    child: SafeArea(
                      child: FloatingView(
                        padding: EdgeInsets.only(
                          top: showChrome ? 56 : 0,
                          bottom: showChrome ? 96 : 0,
                        ),
                        child: CallVideo(calls.local, mirror: mirror),
                      ),
                    ),
                  ),
                AnimatedOpacity(
                  opacity: showChrome ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !showChrome,
                    child: SafeArea(
                      child: Column(
                        children: [
                          _topBar(context, remoteVideo),
                          const Spacer(),
                          if (calls.error != null)
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                calls.error!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          calls.phase == 'ringing'
                              ? _incomingControls()
                              : _controls(context, mobile),
                          const SizedBox(height: 18),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context, bool overVideo) => Container(
    decoration: overVideo
        ? const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black54, Colors.transparent],
            ),
          )
        : null,
    padding: const EdgeInsets.fromLTRB(4, 4, 12, 12),
    child: Row(
      children: [
        IconButton(
          tooltip: 'Back to the app (the call carries on)',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.expand_more),
        ),
        if (overVideo)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  [
                    _status,
                    if (_live) _theirState,
                  ].where((t) => t.isNotEmpty).join(' · '),
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  /// Their name and avatar, and where the call has got to.
  Widget _who(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = (box.biggest.shortestSide * .3).clamp(72.0, 140.0);
      final avatar = CallAvatar(
        label: widget.name,
        seed: widget.seed,
        size: size,
        avatar: widget.avatar,
      );
      final ringing = calls.phase == 'ringing' || calls.phase == 'calling';
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ringing ? RingingHalo(size: size, child: avatar) : avatar,
              SizedBox(height: ringing ? 8 : 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  widget.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _status,
                style: const TextStyle(fontSize: 16, color: Colors.white70),
              ),
              if (_live && _theirState.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (calls.remoteMuted)
                      const Icon(
                        Icons.mic_off,
                        size: 18,
                        color: Colors.white70,
                      ),
                    if (calls.video && calls.remoteCameraOff) ...[
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.videocam_off,
                        size: 18,
                        color: Colors.white70,
                      ),
                    ],
                    const SizedBox(width: 6),
                    Text(
                      _theirState,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ],
              // Room for the controls below.
              const SizedBox(height: 96),
            ],
          ),
        ),
      );
    },
  );

  Widget _incomingControls() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 32),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        CallButton(
          icon: Icons.call_end,
          tooltip: 'Decline',
          caption: 'Decline',
          size: 68,
          background: Colors.red.shade600,
          foreground: Colors.white,
          onPressed: () => widget.act(calls.hangup),
        ),
        CallButton(
          icon: calls.video ? Icons.videocam : Icons.call,
          tooltip: 'Answer',
          caption: 'Answer',
          size: 68,
          background: Colors.green.shade600,
          foreground: Colors.white,
          onPressed: () => widget.act(calls.answer),
        ),
      ],
    ),
  );

  Widget _controls(BuildContext context, bool mobile) {
    final ready = calls.phase != 'ending';
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 14,
      runSpacing: 10,
      children: [
        CallButton(
          icon: calls.muted ? Icons.mic_off : Icons.mic,
          tooltip: calls.muted ? 'Unmute' : 'Mute',
          on: calls.muted,
          onPressed: ready ? calls.mute : null,
        ),
        if (calls.video)
          CallButton(
            icon: calls.cameraOff ? Icons.videocam_off : Icons.videocam,
            tooltip: calls.cameraOff ? 'Turn camera on' : 'Turn camera off',
            on: calls.cameraOff,
            onPressed: ready ? calls.toggleCamera : null,
          ),
        if (mobile && calls.video && !calls.cameraOff)
          CallButton(
            icon: Icons.cameraswitch_outlined,
            tooltip: 'Switch camera',
            onPressed: ready ? () => widget.act(calls.switchCamera) : null,
          ),
        if (mobile)
          CallButton(
            icon: calls.speaker ? Icons.volume_up : Icons.hearing,
            tooltip: calls.speaker ? 'Speaker on' : 'Speaker off',
            on: calls.speaker,
            onPressed: ready ? () => widget.act(calls.toggleSpeaker) : null,
          )
        else if (calls.audioInputs.isNotEmpty || calls.audioOutputs.isNotEmpty)
          CallButton(
            icon: Icons.tune,
            tooltip: 'Microphone and speakers',
            onPressed: () => showCallDevices(
              context,
              listenable: calls,
              inputs: () => calls.audioInputs,
              outputs: () => calls.audioOutputs,
              input: () => calls.audioInput,
              output: () => calls.audioOutput,
              selectInput: (id) => widget.act(() => calls.selectAudioInput(id)),
              selectOutput: (id) =>
                  widget.act(() => calls.selectAudioOutput(id)),
            ),
          ),
        CallButton(
          icon: Icons.call_end,
          tooltip: 'Hang up',
          background: Colors.red.shade600,
          foreground: Colors.white,
          onPressed: ready ? () => widget.act(calls.hangup) : null,
        ),
      ],
    );
  }
}

/// The bar shown over the app during a one-to-one call with its screen
/// closed: who with, how long, and answer, mute and hang up.
class CallBar extends StatelessWidget {
  final Calls calls;
  final String name;
  final VoidCallback onOpen;
  final Future<void> Function(Future<void> Function()) act;
  const CallBar({
    super.key,
    required this.calls,
    required this.name,
    required this.onOpen,
    required this.act,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ringing = calls.phase == 'ringing';
    final text = switch (calls.phase) {
      'ringing' => '${calls.video ? 'Video call' : 'Call'} from $name',
      'calling' => calls.rung ? 'Ringing $name…' : 'Calling $name…',
      'connected' => '$name · ${callDuration(calls.connectedAt)}',
      'reconnecting' => '$name · reconnecting…',
      _ => '$name · ${calls.phase}…',
    };
    return Material(
      color: ringing ? scheme.tertiaryContainer : scheme.primaryContainer,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          child: Row(
            children: [
              Icon(
                ringing ? Icons.ring_volume : Icons.call,
                color: scheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (ringing)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green.shade600,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => act(calls.answer),
                  icon: const Icon(Icons.call, size: 18),
                  label: const Text('Answer'),
                )
              else
                IconButton(
                  tooltip: calls.muted ? 'Unmute' : 'Mute',
                  onPressed: calls.mute,
                  icon: Icon(calls.muted ? Icons.mic_off : Icons.mic),
                ),
              IconButton(
                tooltip: ringing ? 'Decline' : 'Hang up',
                onPressed: () => act(calls.hangup),
                icon: const Icon(Icons.call_end, color: Colors.red),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
