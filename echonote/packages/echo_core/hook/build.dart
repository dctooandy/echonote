import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:logging/logging.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageName = input.packageName;
    final cbuilder = CBuilder.library(
      name: packageName,
      assetName: '${packageName}_bindings_generated.dart',
      sources: ['src/$packageName.c'],
      std: 'c11',
      flags: [
        // Warnings fail the build: they surface in the hook log otherwise,
        // which nobody reads.
        '-Wall', '-Wextra', '-Werror',
        // No fused multiply-add: results stay bit-identical across
        // platforms and to the pure-Dart reference.
        '-ffp-contract=off',
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
