import 'package:flutter/services.dart';

const _channel = MethodChannel('ournet/connection');

/// Starts or stops Android's foreground service that keeps OurNet running,
/// and online, while it is in the background or swiped away. The service
/// shows a notification while it runs and starts again after a restart.
Future<void> keepConnected(bool on) =>
    _channel.invokeMethod<void>(on ? 'start' : 'stop');
