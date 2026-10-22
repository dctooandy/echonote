import 'package:echonote/utils/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatLength', () {
    test('minutes and seconds under an hour', () {
      expect(formatLength(5000), '0:05');
      expect(formatLength(59000), '0:59');
      expect(formatLength(44 * 60000 + 12000), '44:12');
      expect(formatLength(3599000), '59:59');
    });

    test('hours from an hour up', () {
      expect(formatLength(3600000), '1:00:00');
      expect(formatLength(3600000 + 5 * 60000 + 30000), '1:05:30');
    });

    test('rounds to the nearest second', () {
      expect(formatLength(1499), '0:01');
      expect(formatLength(1500), '0:02');
      expect(formatLength(3599500), '1:00:00');
    });

    test('anything under a second reads as one', () {
      expect(formatLength(1), '0:01');
      expect(formatLength(400), '0:01');
    });
  });

  group('formatListDate', () {
    final now = DateTime(2026, 10, 22, 9);

    test('this year: month/day and time to the minute', () {
      expect(formatListDate(DateTime(2026, 10, 22, 14, 30, 5), now), '10/22 14:30');
      expect(formatListDate(DateTime(2026, 1, 3, 8, 5), now), '1/3 08:05');
    });

    test('another year keeps the year', () {
      expect(formatListDate(DateTime(2025, 12, 31, 23, 59), now), '2025/12/31 23:59');
    });
  });
}
