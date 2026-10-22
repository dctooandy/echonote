import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Tells "lying still, face up, on a table" from accelerometer readings
/// (m/s², gravity included, face up reads z ≈ +9.8 on iOS and Android), for
/// the recording screen's desk mode (spec feature-desk-mode).
///
/// Flat needs every reading for [holdFor] to be level within [maxTilt]
/// degrees and within [maxJolt] of the one before; any reading that isn't
/// ends it at once, so picking the phone up shows the full screen right
/// away. Thresholds are first guesses, tuned on a device (spec T3).
class FlatDetector {
  FlatDetector({
    this.holdFor = const Duration(seconds: 3),
    this.maxTilt = 10,
    this.maxJolt = 0.6,
  });

  final Duration holdFor;
  final double maxTilt;
  final double maxJolt;

  DateTime? _flatSince;
  (double, double, double)? _last;

  /// Takes one reading at [at]; returns whether the phone counts as flat.
  bool add(double x, double y, double z, DateTime at) {
    final last = _last;
    _last = (x, y, z);
    final still =
        last == null ||
        math.sqrt(math.pow(x - last.$1, 2) + math.pow(y - last.$2, 2) + math.pow(z - last.$3, 2)) <=
            maxJolt;
    final g = math.sqrt(x * x + y * y + z * z);
    final level = g > 0 && z > 0 && math.acos((z / g).clamp(-1.0, 1.0)) * 180 / math.pi <= maxTilt;
    if (!still || !level) {
      _flatSince = null;
      return false;
    }
    final since = _flatSince ??= at;
    return at.difference(since) >= holdFor;
  }
}

/// Whether the phone lies flat, as it changes; the real accelerometer at
/// 5 readings a second. Without a sensor (or on an error) it says "not
/// flat" and ends, so recording never depends on it.
Stream<bool> watchFlat() {
  final detector = FlatDetector();
  return accelerometerEventStream(samplingPeriod: const Duration(milliseconds: 200))
      .map((e) => detector.add(e.x, e.y, e.z, e.timestamp))
      .transform(
        StreamTransformer<bool, bool>.fromHandlers(
          handleError: (error, _, sink) {
            debugPrint('[FlatDetector] accelerometer unavailable: $error');
            sink
              ..add(false)
              ..close();
          },
        ),
      )
      .distinct();
}
