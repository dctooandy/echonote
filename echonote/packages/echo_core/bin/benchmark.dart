import 'dart:io';

import 'package:echo_core/benchmark.dart';

/// macOS run of the shared benchmark. Build it AOT so the Dart rows are
/// comparable to the app's profile/release builds:
///   dart build cli -t bin/benchmark.dart -o build/benchmark
///   build/benchmark/bundle/bin/benchmark
void main() {
  stdout.writeln('${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
  stdout.writeln('${Platform.numberOfProcessors} cores, Dart ${Platform.version.split(' ').first}');
  final results = runBenchmark(log: stdout.writeln);
  stdout.writeln();
  stdout.writeln(formatResults(results));
}
