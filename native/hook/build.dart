import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// Builds `rust/` with cargo for the target being built and bundles it.
///
/// Everyday builds use the `native-dev` profile; shipped and measured builds
/// use tool/with-native-profile.ps1 for fat LTO (see Cargo.toml).
/// Every package's hook shares `rust/target`, so core, transport and app
/// compile wasmtime once between them rather than once each.
///
/// A target whose Rust standard library is not installed gets no library:
/// `package:ournet_native` then reports itself unavailable and OurNet uses
/// its pure-Dart code, which gives the same results more slowly.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final triple = _triple(code.targetOS, code.targetArchitecture);
    final crate = input.packageRoot.resolve('rust/');
    final profileFile = input.packageRoot.resolve('build-profile.txt');
    output.dependencies.addAll([
      profileFile,
      crate.resolve('Cargo.toml'),
      crate.resolve('Cargo.lock'),
      crate.resolve('src/lib.rs'),
      crate.resolve('src/plugin.rs'),
      crate.resolve('src/tun.rs'),
      crate.resolve('src/device.rs'),
      crate.resolve('src/denoise.rs'),
      crate.resolve('src/desktop.rs'),
      crate.resolve('src/desktop_os.rs'),
      crate.resolve('src/desktop_audio.rs'),
      crate.resolve('wit/plugin.wit'),
    ]);
    if (triple == null || !await _installed(triple)) {
      stderr.writeln(
        'ournet_native: no Rust target for ${code.targetOS} '
        '${code.targetArchitecture}; using pure-Dart crypto.',
      );
      return;
    }
    final target = crate.resolve('target/');
    final profile = (await File.fromUri(profileFile).readAsString()).trim();
    if (profile != 'release' && profile != 'native-dev') {
      throw StateError('Unsupported native build profile: $profile');
    }
    final environment = <String, String>{};
    final prefix = 'CARGO_TARGET_${triple.toUpperCase().replaceAll('-', '_')}';
    if (code.targetOS == OS.android) {
      final clang = code.cCompiler?.compiler;
      if (clang == null) throw StateError('No Android NDK compiler given');
      final api = code.android.targetNdkApi;
      final clangTarget = triple.startsWith('armv7')
          ? 'armv7a-linux-androideabi$api'
          : '$triple$api';
      environment['${prefix}_LINKER'] = clang.toFilePath();
      environment['${prefix}_RUSTFLAGS'] = '-C link-arg=--target=$clangTarget';
      // C parts of dependencies (wasmtime's helpers), built by the cc crate.
      final cc = triple.replaceAll('-', '_');
      environment['CC_$cc'] = clang.toFilePath();
      environment['CFLAGS_$cc'] = '--target=$clangTarget';
      final ar = code.cCompiler?.archiver;
      if (ar != null) environment['AR_$cc'] = ar.toFilePath();
    }
    final watch = Stopwatch()..start();
    final result = await Process.run(
      'cargo',
      [
        'build',
        '--profile',
        profile,
        '--locked',
        '--target',
        triple,
        '--manifest-path',
        crate.resolve('Cargo.toml').toFilePath(),
        '--target-dir',
        target.toFilePath(),
      ],
      environment: environment,
      runInShell: Platform.isWindows,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        'cargo',
        ['build'],
        '${result.stdout}\n${result.stderr}',
        result.exitCode,
      );
    }
    stderr.writeln(
      'ournet_native: $triple ($profile) cargo completed in '
      '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s\n'
      '${result.stderr}',
    );
    // Copied out of the shared target so a library loaded by one package's
    // running tests never blocks another package's build from relinking.
    final name = code.targetOS.dylibFileName('ournet_native');
    final built = File.fromUri(target.resolve('$triple/$profile/$name'));
    final bundled = input.outputDirectory.resolve(name);
    await built.copy(bundled.toFilePath());
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'ournet_native.dart',
        linkMode: DynamicLoadingBundled(),
        file: bundled,
      ),
    );
  });
}

String? _triple(OS os, Architecture arch) => switch ((os, arch)) {
  (OS.android, Architecture.arm64) => 'aarch64-linux-android',
  (OS.android, Architecture.arm) => 'armv7-linux-androideabi',
  (OS.android, Architecture.x64) => 'x86_64-linux-android',
  (OS.android, Architecture.ia32) => 'i686-linux-android',
  (OS.windows, Architecture.x64) => 'x86_64-pc-windows-msvc',
  (OS.windows, Architecture.arm64) => 'aarch64-pc-windows-msvc',
  (OS.linux, Architecture.x64) => 'x86_64-unknown-linux-gnu',
  (OS.linux, Architecture.arm64) => 'aarch64-unknown-linux-gnu',
  (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',
  (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
  (OS.iOS, Architecture.arm64) => 'aarch64-apple-ios',
  _ => null,
};

Future<bool> _installed(String triple) async {
  try {
    final result = await Process.run('rustup', [
      'target',
      'list',
      '--installed',
    ], runInShell: Platform.isWindows);
    if (result.exitCode != 0) return false;
    return (result.stdout as String).split(RegExp(r'\s+')).contains(triple);
  } on ProcessException {
    return false;
  }
}
