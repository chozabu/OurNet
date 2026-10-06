import 'package:flutter/services.dart';

const _channel = MethodChannel('ournet/connection');

/// Starts or stops Android's foreground service that keeps OurNet running,
/// and online, while it is in the background or swiped away. The service
/// shows a notification while it runs and starts again after a restart.
Future<void> keepConnected(bool on) =>
    _channel.invokeMethod<void>(on ? 'start' : 'stop');

/// What Android is letting the "stay connected" service do.
class ConnectionStatus {
  /// The service is running.
  final bool running;

  /// It may read location in the background. Android refuses this when the
  /// service starts with OurNet out of sight; starting it again while OurNet
  /// is open fixes it.
  final bool location;

  /// Battery optimisation applies to OurNet, which lets some phones stop the
  /// service, or hold back its network, when the screen is off.
  final bool batteryRestricted;

  /// Incoming calls may take over the screen when it is off or locked
  /// (Android 14 lets people turn this off per app).
  final bool fullScreen;

  const ConnectionStatus({
    required this.running,
    required this.location,
    required this.batteryRestricted,
    this.fullScreen = true,
  });
}

Future<ConnectionStatus?> connectionStatus() async {
  final status = await _channel.invokeMapMethod<String, Object?>('status');
  if (status == null) return null;
  return ConnectionStatus(
    running: status['running'] == true,
    location: status['location'] == true,
    batteryRestricted: status['batteryRestricted'] == true,
    fullScreen: status['fullScreen'] != false,
  );
}

/// Opens OurNet's page in Android's settings, where battery use can be made
/// unrestricted. False when the page could not be opened.
Future<bool> openBatterySettings() async =>
    await _channel.invokeMethod<bool>('batterySettings') ?? false;

/// Opens Android's page for letting OurNet's calls take over the screen.
Future<bool> openFullScreenSettings() async =>
    await _channel.invokeMethod<bool>('fullScreenSettings') ?? false;

/// Tells Android a call is [ringing] (shown over the lock screen, turning the
/// screen on) or [active] (shown over the lock screen, keeping the microphone,
/// and the camera for [video], while the screen is off).
Future<void> callState({
  required bool ringing,
  required bool active,
  required bool video,
}) => _channel.invokeMethod<void>('call', {
  'ringing': ringing,
  'active': active,
  'video': video,
});

/// Calls [changed] when Android moves to another network (Wi-Fi to mobile
/// data, or back after losing it).
void onNetworkChanged(void Function() changed) {
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'networkChanged') changed();
  });
}
