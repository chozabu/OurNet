import 'dart:async';

import 'package:ournet/services/thumbnails.dart';
import 'package:ournet_core/ournet_core.dart';

/// Widget tests run on a fake clock whose timers only advance when pumped, so
/// core's cooperative event-loop yields and the preview-storage pause for
/// scrolling to settle are disabled for them.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TimeSlice.enabled = false;
  Thumbnails.quiet = () async {};
  await testMain();
}
