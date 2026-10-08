import 'dart:math' as math;
import 'dart:typed_data';

import 'package:echo_core/echo_core.dart';
import 'package:test/test.dart';

/// Seeded noise covering the full int16 range, extremes included.
Int16List _samples(int n, {int seed = 1, int amplitude = 32767}) {
  final rnd = math.Random(seed);
  final out = Int16List(n);
  for (var i = 0; i < n; i++) {
    out[i] = rnd.nextInt(2 * amplitude + 1) - amplitude;
  }
  if (n > 2) {
    out[0] = -32768;
    out[1] = 32767;
  }
  return out;
}

/// A 100 ms chunk (1600 samples at 16 kHz) of a tone at [level] (0..1),
/// plus a little noise.
Int16List _chunk(double level, int index) {
  final rnd = math.Random(index);
  return Int16List.fromList([
    for (var i = 0; i < 1600; i++)
      (level * 32767 * math.sin(2 * math.pi * 440 * (index * 1600 + i) / 16000) +
              rnd.nextInt(41) -
              20)
          .round()
          .clamp(-32768, 32767),
  ]);
}

Matcher _closeRel(double expected) => closeTo(expected, expected.abs() * 1e-6 + 1e-12);

void main() {
  final buffered = EchoBufferedCore();
  tearDownAll(buffered.dispose);

  group('pcm16ToFloat', () {
    test('C matches the Dart reference exactly (both paths)', () {
      final s = _samples(4801);
      final expected = DartReference.pcm16ToFloat(s);
      expect(pcm16ToFloat(s), expected);
      expect(buffered.pcm16ToFloat(s), expected);
    });

    test('-32768 maps to exactly -1.0', () {
      expect(pcm16ToFloat(Int16List.fromList([-32768, 0, 16384])), [-1.0, 0.0, 0.5]);
    });

    test('a view with an offset is read from the right place', () {
      final s = _samples(100);
      final view = Int16List.sublistView(s, 7, 57);
      expect(pcm16ToFloat(view), DartReference.pcm16ToFloat(view));
    });
  });

  group('rms', () {
    test('C matches the Dart reference (both paths)', () {
      for (final seed in [1, 2, 3]) {
        final s = _samples(1600, seed: seed, amplitude: 3000 * seed);
        final expected = DartReference.rms(s);
        expect(rms(s), _closeRel(expected));
        expect(buffered.rms(s), _closeRel(expected));
      }
    });

    test('full-scale input is 1.0, silence is 0', () {
      expect(rms(Int16List(10)..fillRange(0, 10, -32768)), 1.0);
      expect(rms(Int16List(10)), 0.0);
    });
  });

  group('waveform', () {
    test('C matches the Dart reference (both paths)', () {
      final s = _samples(16000);
      for (final buckets in [1, 7, 100, 16000]) {
        final expected = DartReference.waveform(s, buckets);
        final zeroCopy = waveform(s, buckets);
        final viaBuffer = buffered.waveform(s, buckets);
        expect(zeroCopy.length, expected.length);
        for (var i = 0; i < expected.length; i++) {
          expect(zeroCopy[i], _closeRel(expected[i]));
          expect(viaBuffer[i], _closeRel(expected[i]));
        }
      }
    });

    test('more buckets than samples gives one bucket per sample', () {
      final w = waveform(Int16List.fromList([-32768, 16384, 0]), 10);
      expect(w, [1.0, 0.5, 0.0]);
    });
  });

  group('edge cases', () {
    final empty = Int16List(0);
    test('empty input', () {
      expect(pcm16ToFloat(empty), isEmpty);
      expect(rms(empty), 0.0);
      expect(waveform(empty, 10), isEmpty);
      expect(buffered.pcm16ToFloat(empty), isEmpty);
      expect(buffered.rms(empty), 0.0);
      expect(buffered.waveform(empty, 10), isEmpty);
    });

    test('zero or negative buckets', () {
      final s = _samples(10);
      expect(waveform(s, 0), isEmpty);
      expect(waveform(s, -3), isEmpty);
      expect(buffered.waveform(s, 0), isEmpty);
    });
  });

  group('EchoBufferedCore', () {
    test('reuses its buffers and grows only when needed', () {
      final core = EchoBufferedCore();
      final small = _samples(1600);
      core.rms(small); // input buffer
      core.pcm16ToFloat(small); // output buffer
      final afterFirst = core.allocations;
      for (var i = 0; i < 100; i++) {
        core.pcm16ToFloat(small);
      }
      expect(core.allocations, afterFirst);
      core.pcm16ToFloat(_samples(3200)); // both buffers grow
      expect(core.allocations, afterFirst + 2);
      core.dispose();
    });

    test('dispose is idempotent; use after dispose throws', () {
      final core = EchoBufferedCore()..rms(_samples(10));
      core.dispose();
      core.dispose();
      expect(() => core.rms(_samples(10)), throwsStateError);
    });
  });

  group('EchoVad', () {
    test('Dart config defaults match the C defaults', () {
      final c = nativeDefaultVadConfig();
      const d = EchoVadConfig();
      final f32 = Float32List.fromList([
        d.initialNoiseFloor,
        d.rmsMin,
        d.voiceRatio,
        d.noiseFloorCap,
        d.fallRate,
        d.riseRate,
      ]);
      expect([
        c.initialNoiseFloor,
        c.rmsMin,
        c.voiceRatio,
        c.noiseFloorCap,
        c.fallRate,
        c.riseRate,
      ], f32);
    });

    test('makes the same decisions as the Dart reference', () {
      final vad = EchoVad();
      final reference = DartReferenceVad();
      // Quiet room, then speech, then quiet again, then a loud room.
      final levels = [
        for (var i = 0; i < 30; i++) 0.001,
        for (var i = 0; i < 30; i++) 0.2,
        for (var i = 0; i < 30; i++) 0.001,
        for (var i = 0; i < 30; i++) 0.03,
      ];
      final decisions = <bool>[];
      for (var i = 0; i < levels.length; i++) {
        final chunk = _chunk(levels[i], i);
        final decision = vad.process(chunk);
        expect(decision, reference.process(chunk), reason: 'chunk $i');
        decisions.add(decision);
      }
      expect(decisions.sublist(0, 30).any((v) => v), isFalse, reason: 'silence');
      expect(decisions.sublist(35, 60).every((v) => v), isTrue, reason: 'speech');
      vad.dispose();
    });

    test('empty input is not voiced and does not change state', () {
      final vad = EchoVad();
      final reference = DartReferenceVad();
      expect(vad.process(Int16List(0)), isFalse);
      final chunk = _chunk(0.2, 0);
      expect(vad.process(chunk), reference.process(chunk));
      vad.dispose();
    });

    test('reset returns to the initial noise floor', () {
      final vad = EchoVad();
      final fresh = EchoVad();
      for (var i = 0; i < 20; i++) {
        vad.process(_chunk(0.03, i));
      }
      vad.reset();
      final probe = _chunk(0.02, 99);
      expect(vad.process(probe), fresh.process(probe));
      vad.dispose();
      fresh.dispose();
    });

    test('dispose is idempotent; use after dispose throws', () {
      final vad = EchoVad()..dispose();
      vad.dispose();
      expect(() => vad.process(_chunk(0.2, 0)), throwsStateError);
      expect(vad.reset, throwsStateError);
    });
  });
}
