import 'dart:async';

import 'package:ournet_core/ournet_core.dart';

/// Widget tests run on a fake clock whose timers only advance when pumped, so
/// core's cooperative event-loop yields are disabled for them.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TimeSlice.enabled = false;
  await testMain();
}
