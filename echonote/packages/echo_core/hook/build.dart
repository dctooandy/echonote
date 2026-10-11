import 'package:code_assets/code_assets.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:logging/logging.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageName = input.packageName;
    final targetOS = input.config.code.targetOS;
    final isElf = targetOS == OS.android || targetOS == OS.linux;
    final cbuilder = CBuilder.library(
      name: packageName,
      assetName: '${packageName}_bindings_generated.dart',
      sources: ['src/$packageName.cpp'],
      language: .cpp,
      std: 'c++17',
      // Static libc++ on Android, like whisper's NDK CMake default: the
      // shared one would have to be packaged into the APK separately. Two
      // copies in one app are fine because only C crosses between them.
      cppLinkStdLib: targetOS == OS.android ? 'c++_static' : null,
      flags: [
        // Warnings fail the build: they surface in the hook log otherwise,
        // which nobody reads.
        '-Wall', '-Wextra', '-Werror',
        // No fused multiply-add: results stay bit-identical across
        // platforms and to the pure-Dart reference.
        '-ffp-contract=off',
        // Export only the EC_EXPORT C API; echo_core:: stays internal.
        '-fvisibility=hidden',
        if (isElf) ...[
          // Keep the statically linked libc++/libc++abi symbols local, so
          // they can't bind to another library's C++ runtime in the same
          // process (whisper has its own).
          '-Wl,--exclude-libs,ALL',
          // Drop the parts of libc++ nothing calls.
          '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
        ],
      ],
      optimizationLevel: .o3,
    );
    await cbuilder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = .ALL
        ..onRecord.listen((record) => print(record.message)),
    );
  });
}
