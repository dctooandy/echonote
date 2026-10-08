import 'dart:typed_data';

import 'package:echo_core/echo_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Confirms the echo_core native asset is bundled and callable on a real
/// iOS build (simulator or device), not just in host `dart test`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('echo_core native code runs on device', () {
    final samples = Int16List.fromList([-32768, 16384, 0, 32767]);
    expect(pcm16ToFloat(samples), DartReference.pcm16ToFloat(samples));
    expect(rms(samples), closeTo(DartReference.rms(samples), 1e-6));
    final vad = EchoVad();
    expect(vad.process(Int16List(1600)), isFalse);
    vad.dispose();
  });
}
