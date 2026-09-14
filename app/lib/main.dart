import 'package:flutter/material.dart';
import 'services/session.dart';
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
