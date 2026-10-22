import 'package:echonote/services/flat_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 10, 22, 14);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  /// Feeds readings every 200 ms from [startMs]; returns the last answer.
  bool feed(FlatDetector d, List<(double, double, double)> readings, {int startMs = 0}) {
    var flat = false;
    for (final (i, (x, y, z)) in readings.indexed) {
      flat = d.add(x, y, z, at(startMs + i * 200));
    }
    return flat;
  }

  const lying = (0.05, -0.08, 9.80);

  test('flat only after three steady seconds', () {
    final d = FlatDetector();

    expect(feed(d, List.filled(15, lying)), isFalse, reason: '2.8 s');
    expect(d.add(0.05, -0.08, 9.80, at(3000)), isTrue);
  });

  test('a slight slope still counts as flat', () {
    final d = FlatDetector();
    // About 6° of tilt.
    expect(feed(d, List.filled(16, (1.0, 0.0, 9.75))), isTrue);
  });

  test('tilted, standing or face down is never flat', () {
    // About 20° of tilt.
    expect(feed(FlatDetector(), List.filled(30, (3.3, 0.0, 9.2))), isFalse);
    expect(feed(FlatDetector(), List.filled(30, (0.0, 9.8, 0.3))), isFalse, reason: 'held upright');
    expect(feed(FlatDetector(), List.filled(30, (0.0, 0.0, -9.8))), isFalse, reason: 'face down');
  });

  test('picking it up ends flat at once', () {
    final d = FlatDetector();
    expect(feed(d, List.filled(16, lying)), isTrue);

    expect(d.add(2.5, 3.0, 8.5, at(3400)), isFalse);
  });

  test('a knock restarts the count', () {
    final d = FlatDetector();
    expect(feed(d, List.filled(16, lying)), isTrue);

    expect(d.add(0.05, -0.08, 11.0, at(3400)), isFalse, reason: 'the table was knocked');
    // Settling back is a jolt too, so the count restarts from the reading
    // after it (3800 ms).
    expect(feed(d, List.filled(16, lying), startMs: 3600), isFalse, reason: 'counting again');
    expect(d.add(0.05, -0.08, 9.80, at(6800)), isTrue);
  });

  test('small table vibrations are tolerated', () {
    final d = FlatDetector();
    final readings = [for (var i = 0; i < 16; i++) (0.05, -0.08, i.isEven ? 9.80 : 9.95)];

    expect(feed(d, readings), isTrue);
  });
}
