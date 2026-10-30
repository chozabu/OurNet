import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

const _channel = MethodChannel('ournet/device');

/// Power and network conditions for relaying for friends
/// (docs/FRIEND_RELAY.md): from Android on phones, from the native library
/// on Windows and Linux (on a worker isolate: Windows asks COM), unknown
/// elsewhere.
Future<RelayConditions> relayConditions() async {
  try {
    if (Platform.isAndroid) {
      final state = await _channel.invokeMapMethod<String, bool>('power');
      return RelayConditions(
        mains: state?['mains'],
        saver: state?['saver'] ?? false,
        metered: state?['metered'],
      );
    }
    if (Platform.isWindows || Platform.isLinux) {
      final state = await Isolate.run(NativePower.state);
      return RelayConditions(
        mains: state.mains,
        saver: state.saver,
        metered: state.metered,
      );
    }
  } catch (_) {}
  return const RelayConditions();
}
