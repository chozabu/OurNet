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

  const ConnectionStatus({
    required this.running,
    required this.location,
    required this.batteryRestricted,
  });
}

Future<ConnectionStatus?> connectionStatus() async {
  final status = await _channel.invokeMapMethod<String, Object?>('status');
  if (status == null) return null;
  return ConnectionStatus(
    running: status['running'] == true,
    location: status['location'] == true,
    batteryRestricted: status['batteryRestricted'] == true,
  );
}

/// Opens OurNet's page in Android's settings, where battery use can be made
/// unrestricted. False when the page could not be opened.
Future<bool> openBatterySettings() async =>
    await _channel.invokeMethod<bool>('batterySettings') ?? false;

/// Calls [changed] when Android moves to another network (Wi-Fi to mobile
/// data, or back after losing it).
void onNetworkChanged(void Function() changed) {
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'networkChanged') changed();
  });
}
