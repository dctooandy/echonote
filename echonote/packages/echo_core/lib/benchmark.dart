/// Benchmark shared by the macOS CLI (`bin/benchmark.dart`) and the iPhone
/// run (the app's `integration_test/echo_core_benchmark_test.dart`), so both
/// measure exactly the same work.
///
/// Workload: two hours of 16 kHz mono PCM16 fed in 100 ms chunks (72,000
/// calls per function), the granularity of a real live recording. To keep
/// memory small and generation out of the timing, one minute of synthetic
/// signal is generated up front and the chunks cycle through it.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'echo_core.dart';

/// Speech-like synthetic signal: 2 s of syllable-modulated tones, then 1 s
/// of near-silence, repeating, plus low noise. Fixed seed, so anyone can
/// reproduce it.
Int16List synthesizeSignal({int seconds = 60, int sampleRate = 16000, int seed = 42}) {
  final rnd = math.Random(seed);
  final out = Int16List(seconds * sampleRate);
  for (var i = 0; i < out.length; i++) {
    final t = i / sampleRate;
    final speaking = t % 3 < 2;
    // ~4 syllables per second.
    final envelope = speaking ? 0.5 + 0.5 * math.sin(2 * math.pi * 4 * t) : 0.02;
    final tone = math.sin(2 * math.pi * 220 * t) * 0.6 + math.sin(2 * math.pi * 660 * t) * 0.3;
    final noise = (rnd.nextDouble() * 2 - 1) * 0.01;
    out[i] = ((tone * envelope * 0.4 + noise) * 32767).round().clamp(-32768, 32767);
  }
  return out;
}

class BenchmarkResult {
  BenchmarkResult(this.function, this.implementation, this.elapsed, this.calls);

  final String function;
  final String implementation;
  final Duration elapsed;
  final int calls;

  double get microsPerCall => elapsed.inMicroseconds / calls;
}

/// Runs every function × implementation over [audio] of chunked input.
/// [log] receives one line per result as it finishes.
List<BenchmarkResult> runBenchmark({
  Duration audio = const Duration(hours: 2),
  int chunkSamples = 1600,
  int waveformBuckets = 32,
  void Function(String line)? log,
}) {
  final signal = synthesizeSignal();
  final chunksInSignal = signal.length ~/ chunkSamples;
  final calls = audio.inMilliseconds * 16 ~/ chunkSamples;
  final chunks = [
    for (var c = 0; c < chunksInSignal; c++)
      Int16List.sublistView(signal, c * chunkSamples, (c + 1) * chunkSamples),
  ];

  final results = <BenchmarkResult>[];
  final buffered = EchoBufferedCore();
  // Sink so no implementation's work can be optimized away.
  var sink = 0.0;

  void measure(String function, String implementation, double Function(Int16List chunk) body) {
    // Warm-up: first calls pay for lookups, page faults and buffer growth.
    for (var i = 0; i < 1000; i++) {
      sink += body(chunks[i % chunks.length]);
    }
    final watch = Stopwatch()..start();
    for (var i = 0; i < calls; i++) {
      sink += body(chunks[i % chunks.length]);
    }
    watch.stop();
    final result = BenchmarkResult(function, implementation, watch.elapsed, calls);
    results.add(result);
    log?.call(
      '$function / $implementation: ${result.elapsed.inMilliseconds} ms total, '
      '${result.microsPerCall.toStringAsFixed(2)} µs per call',
    );
  }

  measure('pcm16ToFloat', 'Dart', (c) => DartReference.pcm16ToFloat(c)[1]);
  measure('pcm16ToFloat', 'C zero-copy', (c) => pcm16ToFloat(c)[1]);
  measure('pcm16ToFloat', 'C native buffer', (c) => buffered.pcm16ToFloat(c)[1]);

  measure('rms', 'Dart', DartReference.rms);
  measure('rms', 'C zero-copy', rms);
  measure('rms', 'C native buffer', buffered.rms);

  measure('waveform', 'Dart', (c) => DartReference.waveform(c, waveformBuckets)[0]);
  measure('waveform', 'C zero-copy', (c) => waveform(c, waveformBuckets)[0]);
  measure('waveform', 'C native buffer', (c) => buffered.waveform(c, waveformBuckets)[0]);

  final dartVad = DartReferenceVad();
  final cVad = EchoVad();
  measure('vad', 'Dart', (c) => dartVad.process(c) ? 1 : 0);
  measure('vad', 'C zero-copy', (c) => cVad.process(c) ? 1 : 0);
  cVad.dispose();

  log?.call('native buffer (re)allocations: ${buffered.allocations}; checksum $sink');
  buffered.dispose();
  return results;
}

/// Markdown table of [results], with each C row's speed-up over Dart.
String formatResults(List<BenchmarkResult> results) {
  final lines = <String>[
    '| 函式 | 實作 | 總耗時 (ms) | 每次呼叫 (µs) | 相對純 Dart |',
    '| --- | --- | ---: | ---: | ---: |',
  ];
  for (final r in results) {
    final dart = results.firstWhere((d) => d.function == r.function && d.implementation == 'Dart');
    final speedUp = dart.microsPerCall / r.microsPerCall;
    lines.add(
      '| `${r.function}` | ${r.implementation} | ${r.elapsed.inMilliseconds} | '
      '${r.microsPerCall.toStringAsFixed(2)} | ${speedUp.toStringAsFixed(1)}× |',
    );
  }
  return lines.join('\n');
}
