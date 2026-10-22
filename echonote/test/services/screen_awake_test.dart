import 'package:echonote/services/screen_awake.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<bool> calls;
  late ScreenAwake awake;

  setUp(() {
    calls = [];
    awake = ScreenAwake(setKeepAwake: (on) async => calls.add(on));
  });

  test('the first holder turns it on, the last one off', () async {
    await awake.hold('recording');
    await awake.hold('re-transcribe');
    expect(calls, [true]);

    await awake.release('recording');
    expect(awake.isOn, isTrue);
    expect(calls, [true], reason: 'still held by re-transcribe');

    await awake.release('re-transcribe');
    expect(awake.isOn, isFalse);
    expect(calls, [true, false]);
  });

  test('holding or releasing twice changes nothing', () async {
    await awake.hold('a');
    await awake.hold('a');
    await awake.release('a');
    await awake.release('a');
    await awake.release('never held');

    expect(calls, [true, false]);
  });

  test('quick changes end in the right state, without extra calls', () async {
    final pending = [awake.hold('a'), awake.release('a'), awake.hold('b')];
    await Future.wait(pending);

    expect(awake.isOn, isTrue);
    expect(calls.last, isTrue);
  });

  test('a failing platform call does not throw, and is retried next time', () async {
    var fail = true;
    final flaky = ScreenAwake(
      setKeepAwake: (on) async {
        if (fail) throw StateError('no native side');
        calls.add(on);
      },
    );

    await flaky.hold('a');
    fail = false;
    await flaky.hold('b');

    expect(calls, [true]);
  });
}
