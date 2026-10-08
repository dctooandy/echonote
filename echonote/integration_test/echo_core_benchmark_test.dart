import 'package:echo_core/benchmark.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Same benchmark as packages/echo_core/bin/benchmark.dart, on a phone.
/// Run in profile mode — debug mode is JIT and makes the Dart rows
/// meaningless:
///   `flutter drive --profile -d DEVICE_ID \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/echo_core_benchmark_test.dart`
/// Results land in build/integration_response_data.json.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('echo_core benchmark', () {
    final lines = <String>[];
    final results = runBenchmark(log: (line) {
      lines.add(line);
      debugPrint(line);
    });
    final table = formatResults(results);
    debugPrint(table);
    binding.reportData = {'lines': lines, 'table': table};
  }, timeout: const Timeout(Duration(minutes: 10)));
}
