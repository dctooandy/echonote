import 'package:echo_core/echo_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Confirms the echo_core native asset is bundled and callable on a real
/// iOS build (simulator or device), not just in host `dart test`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('echo_core native code runs on device', () {
    expect(sum(24, 18), 42);
  });
}
