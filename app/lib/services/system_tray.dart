import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('ournet/tray');

/// The notification area icon and starting on sign in; see
/// windows/runner/system_tray.cpp and linux/runner/system_tray.cc.
/// While OurNet is kept there, closing the window hides it and OurNet stays
/// connected to friends, showing notifications, until quit from the icon.
abstract final class SystemTray {
  /// Whether this system can start OurNet on sign in and keep it in a tray.
  static bool get supported => Platform.isWindows || Platform.isLinux;

  /// Whether an icon would be seen: always on Windows, and on Linux where
  /// the desktop shows StatusNotifierItems (KDE does; Steam Deck's Game
  /// Mode and plain GNOME do not). Found by [load].
  static bool hosted = Platform.isWindows;

  static Future<void> load() async {
    if (!Platform.isLinux) return;
    try {
      hosted = await _channel.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      hosted = false;
    }
  }

  /// Takes [profile] for this window. False when another OurNet window holds
  /// it, which is asked to show itself unless [show] is false.
  static Future<bool> claim(String profile, {bool show = true}) async {
    try {
      return await _channel.invokeMethod<bool>('claim', {
            'profile': profile,
            'show': show,
          }) ??
          true;
    } on MissingPluginException {
      return true;
    }
  }

  /// Shows or removes the icon, and with it whether closing hides the window.
  static Future<void> keep(bool on) =>
      _channel.invokeMethod<void>('keep', {'on': on});

  /// Unread activity, in the icon's tooltip.
  static Future<void> unread(int count) =>
      _channel.invokeMethod<void>('unread', {'count': count});

  /// Brings the window back, from hidden or minimised.
  static Future<void> show() => _channel.invokeMethod<void>('show');

  /// A short message from the icon.
  static Future<void> hint(String title, String text) =>
      _channel.invokeMethod<void>('hint', {'title': title, 'text': text});

  /// Whether OurNet starts, into the tray, when this person signs in.
  static Future<bool> startsWithWindows() async =>
      await _channel.invokeMethod<bool>('startup') ?? false;

  /// Throws [StartupRefused] when Windows or the person's organisation keeps
  /// it as it is.
  static Future<void> setStartsWithWindows(bool on) async {
    try {
      await _channel.invokeMethod<void>('setStartup', {'on': on});
    } on PlatformException catch (e) {
      throw StartupRefused(
        e.message ?? 'Windows did not allow changing startup apps.',
      );
    }
  }

  /// Called when closing the window hid it in the tray.
  static set onClosed(void Function()? handler) =>
      _channel.setMethodCallHandler(
        handler == null
            ? null
            : (call) async {
                if (call.method == 'closed') handler();
              },
      );
}

/// Why starting with Windows could not be changed, to show as it is.
class StartupRefused implements Exception {
  const StartupRefused(this.message);
  final String message;

  @override
  String toString() => message;
}
