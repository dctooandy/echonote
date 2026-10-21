import 'package:echonote/models/recording.dart';
import 'package:echonote/services/analysis_service.dart';
import 'package:flutter_test/flutter_test.dart';

final _segments = [
  TranscriptSegment(startMs: 1000, endMs: 2000, text: '甲'),
  TranscriptSegment(startMs: 2000, endMs: 5000, text: '乙'),
  TranscriptSegment(startMs: 5000, endMs: 9000, text: '丙'),
];

UserNote _note(String id, int timestampMs, {String? text}) => UserNote(
  id: id,
  timestampMs: timestampMs,
  kind: text == null ? UserNoteKind.star : UserNoteKind.text,
  text: text,
  createdAt: DateTime(2026, 10, 21),
);

void main() {
  group('segmentIndexFor', () {
    test('picks the segment the timestamp falls in', () {
      expect(segmentIndexFor(3000, _segments), 1);
    });

    test('a segment start belongs to that segment', () {
      expect(segmentIndexFor(5000, _segments), 2);
    });

    test('before the first segment maps to the first', () {
      expect(segmentIndexFor(0, _segments), 0);
    });

    test('past the end maps to the last', () {
      expect(segmentIndexFor(60000, _segments), 2);
    });
  });

  group('buildHighlights', () {
    test('sends notes in time order with star text as null', () {
      final result = buildHighlights([
        _note('late', 6000, text: '報價要確認'),
        _note('early', 1500),
      ], _segments);

      expect(result.payload, [
        {'note_index': 0, 'segment_index': 0, 'text': null},
        {'note_index': 1, 'segment_index': 2, 'text': '報價要確認'},
      ]);
      expect(result.noteIds, ['early', 'late']);
    });

    test('no notes means no highlights', () {
      final result = buildHighlights([], _segments);

      expect(result.payload, isEmpty);
      expect(result.noteIds, isEmpty);
    });
  });

  group('resolveHighlightContexts', () {
    test('maps note indices back to note ids', () {
      expect(
        resolveHighlightContexts([
          {'note_index': 1, 'context': '討論報價'},
          {'note_index': 0, 'context': '開場'},
        ], ['a', 'b']),
        {'a': '開場', 'b': '討論報價'},
      );
    });

    test('drops unknown indices and malformed entries', () {
      expect(
        resolveHighlightContexts([
          {'note_index': 5, 'context': '不存在'},
          {'note_index': -1, 'context': '負數'},
          {'note_index': 0},
          'garbage',
          {'note_index': 0, 'context': '有效'},
        ], ['a']),
        {'a': '有效'},
      );
    });

    test('a missing field gives no contexts', () {
      expect(resolveHighlightContexts(null, ['a']), isEmpty);
    });
  });
}
