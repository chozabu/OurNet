import 'dart:io';

/// The Windows network helper (native/tun-helper): a service that owns the
/// Wintun adapter VPN plugins use, so OurNet never runs as administrator.
/// It is installed once, from the copy beside the app, after Windows asks
/// the person (UAC); an app that ships a newer helper installs it again.
abstract final class WindowsTun {
  /// The pipes' name, as the native host opens them.
  static const pipe = 'ournet-tun';
  static const _service = 'ournet-tun';

  static String get _installed =>
      '${Platform.environment['ProgramData'] ?? r'C:\ProgramData'}'
      r'\OurNet\tun\ournet-tun.exe';

  static String get _bundled =>
      '${File(Platform.resolvedExecutable).parent.path}\\ournet-tun.exe';

  /// Makes sure the helper is installed, current and running.
  static Future<void> ensure() async {
    final bundled = await _version(_bundled);
    if (bundled == null) {
      throw StateError('This build has no network helper (ournet-tun.exe)');
    }
    final installed = await _version(_installed);
    // Starting a stopped SYSTEM service needs elevation too; installing
    // again starts it.
    if (installed == null || installed < bundled || !await _running()) {
      await _install();
    }
    for (var i = 0; i < 50 && !await _running(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!await _running()) throw StateError('The network helper did not start');
  }

  static Future<int?> _version(String exe) async {
    if (!await File(exe).exists()) return null;
    try {
      final r = await Process.run(exe, ['version']);
      return r.exitCode == 0 ? int.tryParse('${r.stdout}'.trim()) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _running() async {
    final r = await Process.run('sc.exe', ['query', _service]);
    return r.exitCode == 0 && '${r.stdout}'.contains('RUNNING');
  }

  /// This person's account SID: only they (and administrators) may use the
  /// helper's pipes.
  static Future<String> _sid() async {
    final r = await Process.run('whoami', ['/user', '/fo', 'csv', '/nh']);
    final sid = RegExp(r'S-1-[0-9-]+').firstMatch('${r.stdout}')?.group(0);
    if (sid == null) throw StateError('Could not tell who is signed in');
    return sid;
  }

  /// Runs the bundled helper's installer elevated: Windows asks first.
  static Future<void> _install() async {
    final sid = await _sid();
    final exe = _bundled.replaceAll("'", "''");
    final r = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "\$p = Start-Process -FilePath '$exe' -ArgumentList 'install','--user','$sid' "
          '-Verb RunAs -WindowStyle Hidden -Wait -PassThru; exit \$p.ExitCode',
    ]);
    if (r.exitCode != 0) {
      throw StateError(
        'Windows did not install the network helper'
        '${'${r.stderr}'.contains('canceled') ? ' (not allowed)' : ''}',
      );
    }
  }
}
