import 'dart:math' as math;
import 'dart:typed_data';

import 'vad_config.dart';

/// Pure-Dart versions of the C functions, line for line. Tests compare the C
/// results against these; the benchmark measures what moving to C buys.
abstract final class DartReference {
  static Float32List pcm16ToFloat(Int16List samples) {
    final out = Float32List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      out[i] = samples[i] / 32768.0;
    }
    return out;
  }

  static double rms(Int16List samples) {
    if (samples.isEmpty) return 0;
    return math.sqrt(_meanSquare(samples));
  }

  static Float32List waveform(Int16List samples, int buckets) {
    final n = samples.length;
    if (n == 0 || buckets <= 0) return Float32List(0);
    final count = math.min(buckets, n);
    final out = Float32List(count);
    for (var b = 0; b < count; b++) {
      final start = b * n ~/ count;
      final end = (b + 1) * n ~/ count;
      var peak = 0;
      for (var i = start; i < end; i++) {
        final v = samples[i].abs();
        if (v > peak) peak = v;
      }
      out[b] = peak / 32768.0;
    }
    return out;
  }

  static double _meanSquare(Int16List samples) {
    var sum = 0.0;
    for (final sample in samples) {
      final s = sample / 32768.0;
      sum += s * s;
    }
    return sum / samples.length;
  }
}

/// Pure-Dart counterpart of `ec_vad`, for comparison with [EchoVad].
class DartReferenceVad {
  DartReferenceVad([this.config = const EchoVadConfig()])
    : _noiseFloor = _toFloat(config.initialNoiseFloor);

  final EchoVadConfig config;
  double _noiseFloor;

  bool process(Int16List samples) {
    if (samples.isEmpty) return false;
    // Every step rounded to float exactly where the C code computes in
    // float, so both make identical decisions on the same input.
    final f = _toFloat;
    final rms = f(math.sqrt(DartReference._meanSquare(samples)));
    final rate = rms < _noiseFloor ? f(config.fallRate) : f(config.riseRate);
    _noiseFloor = f(_noiseFloor + f(rate * f(rms - _noiseFloor)));
    if (_noiseFloor > f(config.noiseFloorCap)) _noiseFloor = f(config.noiseFloorCap);
    final ratioThreshold = f(f(config.voiceRatio) * _noiseFloor);
    final rmsMin = f(config.rmsMin);
    final threshold = ratioThreshold > rmsMin ? ratioThreshold : rmsMin;
    return rms >= threshold;
  }

  void reset() => _noiseFloor = _toFloat(config.initialNoiseFloor);

  static final _f32 = Float32List(1);
  static double _toFloat(double v) {
    _f32[0] = v;
    return _f32[0];
  }
}
