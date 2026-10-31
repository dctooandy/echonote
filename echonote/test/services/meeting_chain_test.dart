import 'package:echonote/models/recording.dart';
import 'package:echonote/services/meeting_chain.dart';
import 'package:echonote/utils/format.dart';
import 'package:flutter_test/flutter_test.dart';

Recording _r(String id, DateTime createdAt, {String? previous}) => Recording(
  id: id,
  audioName: '$id.m4a',
  createdAt: createdAt,
  model: 'base',
  elapsedSeconds: 0,
  audioFileName: '$id.m4a',
  segments: [],
  previousRecordingId: previous,
);

void main() {
  final a = _r('a', DateTime(2026, 10, 1));
  final b = _r('b', DateTime(2026, 10, 8));
  final c = _r('c', DateTime(2026, 10, 15));
  final d = _r('d', DateTime(2026, 10, 22));

  test('candidates are the earlier meetings, newest first', () {
    expect(previousCandidates(c, [a, d, c, b]).map((r) => r.id), ['b', 'a']);
  });

  test('a meeting created at the same moment or later is never a candidate', () {
    final twin = _r('twin', DateTime(2026, 10, 15));
    expect(previousCandidates(c, [c, twin, d]), isEmpty);
  });

  test('previousOf finds the linked meeting, or null when none or deleted', () {
    expect(previousOf(_r('x', DateTime(2026, 11, 1), previous: 'b'), [a, b, c])?.id, 'b');
    expect(previousOf(_r('x', DateTime(2026, 11, 1)), [a, b]), isNull);
    expect(previousOf(_r('x', DateTime(2026, 11, 1), previous: 'gone'), [a, b]), isNull);
  });

  test('ISO date is the local date, zero-padded', () {
    expect(formatIsoDate(DateTime(2026, 3, 5, 23, 59)), '2026-03-05');
  });
}
