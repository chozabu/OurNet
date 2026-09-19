import 'dart:io';
import 'package:flutter/material.dart';
import 'services/background_sync.dart';
import 'services/session.dart';
import 'services/system_tray.dart';
import 'ui/app.dart';
import 'ui/onboarding.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final profile =
        arguments
            .where((a) => a.startsWith('--profile='))
            .firstOrNull
            ?.substring(10) ??
        'main';
    // Background sync shares this process on Android; see claimProfile.
    if (Platform.isAndroid && profile == 'main') await claimProfile();
    // Opening OurNet again shows the window it already has, perhaps hidden
    // in the tray; starting with Windows twice does nothing.
    if (Platform.isWindows &&
        !await SystemTray.claim(
          profile,
          show: !arguments.contains('--background'),
        )) {
      exit(0);
    }
    final node = await openNode(profile: profile);
    runApp(needsSetup ? SetupApp(node: node) : OurNetApp(node: node));
  } catch (e) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SelectableText('Unable to open your identity securely.\n$e'),
          ),
        ),
      ),
    );
  }
}
