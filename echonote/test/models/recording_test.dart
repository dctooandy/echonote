import 'package:echonote/models/recording.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _legacyJson({List<Map<String, dynamic>>? segments}) => {
  'id': '1721000000000',
  'audio_name': '新錄音 64.m4a',
  'created_at': '2026-07-22T10:00:00.000',
  'model': 'base',
  'elapsed_seconds': 42,
  'audio_file_name': '1721000000000.m4a',
  'segments':
      segments ??
      [
        {'start_ms': 0, 'end_ms': 1500, 'text': '大家好'},
      ],
  'analysis': null,
};

void main() {
  group('Recording JSON', () {
    test('legacy entry without source reads as an import', () {
      final recording = Recording.fromJson(_legacyJson());

      expect(recording.source, RecordingSource.imported);
      expect(recording.segments.single.text, '大家好');
      expect(recording.elapsedSeconds, 42);
    });

    test('unknown source value falls back to import', () {
      final json = _legacyJson()..['source'] = 'something-new';

      expect(Recording.fromJson(json).source, RecordingSource.imported);
    });

    test('live, untranscribed entry round-trips', () {
      final recording = Recording(
        id: '1',
        audioName: '即時錄音',
        createdAt: DateTime(2026, 10, 8, 12),
        model: 'base',
        elapsedSeconds: 0,
        audioFileName: '1.wav',
        segments: [],
        source: RecordingSource.live,
      );

      final json = recording.toJson();
      expect(json['source'], 'live');
      expect(json['segments'], isEmpty);

      final restored = Recording.fromJson(json);
      expect(restored.source, RecordingSource.live);
      expect(restored.segments, isEmpty);
      expect(restored.isTranscribed, isFalse);
      expect(restored.createdAt, recording.createdAt);
    });
  });

  group('isTranscribed', () {
    test('true when segments exist', () {
      expect(Recording.fromJson(_legacyJson()).isTranscribed, isTrue);
    });

    test('becomes true after segments are filled in', () {
      final recording = Recording.fromJson(_legacyJson(segments: []));
      expect(recording.isTranscribed, isFalse);

      recording
        ..segments = [TranscriptSegment(startMs: 0, endMs: 900, text: '好')]
        ..elapsedSeconds = 7;

      expect(recording.isTranscribed, isTrue);
      expect(Recording.fromJson(recording.toJson()).elapsedSeconds, 7);
    });
  });
}
