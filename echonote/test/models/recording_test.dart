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
    test('legacy entry has no duration, and saving it adds none', () {
      final recording = Recording.fromJson(_legacyJson());

      expect(recording.durationMs, isNull);
      expect(recording.toJson().containsKey('duration_ms'), isFalse);
    });

    test('duration round-trips', () {
      final json = _legacyJson()..['duration_ms'] = 2652000;

      final recording = Recording.fromJson(json);
      expect(recording.durationMs, 2652000);
      expect(Recording.fromJson(recording.toJson()).durationMs, 2652000);
    });

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

  group('user context fields', () {
    test('legacy entry reads with empty notes and no flags', () {
      final recording = Recording.fromJson(_legacyJson());

      expect(recording.notes, isEmpty);
      expect(recording.transcriptStaleAnalysis, isFalse);
      expect(recording.dismissedReplacements, isEmpty);
      expect(recording.segments.single.edited, isFalse);
    });

    test('legacy analysis reads with no highlight contexts', () {
      final json = _legacyJson()
        ..['analysis'] = {
          'summary': {'overview': '概要', 'key_points': []},
          'todos': [],
          'structured_minutes': {'title': '', 'attendees': [], 'agenda_items': []},
        };

      expect(Recording.fromJson(json).analysis!.highlightContexts, isEmpty);
    });

    test('notes, flags, edits and highlight contexts round-trip', () {
      final recording = Recording.fromJson(_legacyJson())
        ..notes.addAll([
          UserNote(
            id: 'n1',
            timestampMs: 1200,
            kind: UserNoteKind.star,
            createdAt: DateTime(2026, 10, 21, 9),
          ),
          UserNote(
            id: 'n2',
            timestampMs: 5000,
            kind: UserNoteKind.text,
            text: '報價要再確認',
            createdAt: DateTime(2026, 10, 21, 9, 1),
          ),
        ])
        ..transcriptStaleAnalysis = true
        ..dismissedReplacements.add('太基電→台積電')
        ..analysis = MeetingAnalysis(
          overview: '',
          keyPoints: [],
          todos: [],
          title: '',
          attendees: [],
          agendaItems: [],
          highlightContexts: {'n1': '討論報價'},
        );
      recording.segments.single
        ..text = '大家早'
        ..edited = true;

      final restored = Recording.fromJson(recording.toJson());
      expect(restored.notes.map((n) => n.kind), [UserNoteKind.star, UserNoteKind.text]);
      expect(restored.notes.first.text, isNull);
      expect(restored.notes.last.text, '報價要再確認');
      expect(restored.notes.last.timestampMs, 5000);
      expect(restored.transcriptStaleAnalysis, isTrue);
      expect(restored.dismissedReplacements, ['太基電→台積電']);
      expect(restored.segments.single.text, '大家早');
      expect(restored.segments.single.edited, isTrue);
      expect(restored.analysis!.highlightContexts, {'n1': '討論報價'});
    });
  });

  group('addStarNote', () {
    test('adds a star at the given time', () {
      final notes = <UserNote>[];

      expect(addStarNote(notes, 5000), isTrue);
      expect(notes.single.kind, UserNoteKind.star);
      expect(notes.single.timestampMs, 5000);
      expect(notes.single.text, isNull);
    });

    test('a second tap within a second is the same mark', () {
      final notes = <UserNote>[];
      addStarNote(notes, 5000);

      expect(addStarNote(notes, 5999), isFalse);
      expect(addStarNote(notes, 4001), isFalse);
      expect(notes, hasLength(1));
    });

    test('a second apart is a new mark', () {
      final notes = <UserNote>[];
      addStarNote(notes, 5000);

      expect(addStarNote(notes, 6000), isTrue);
      expect(notes, hasLength(2));
    });

    test('a text note nearby does not block a star', () {
      final notes = [
        UserNote(id: 't', timestampMs: 5000, kind: UserNoteKind.text, text: '備註', createdAt: DateTime(2026)),
      ];

      expect(addStarNote(notes, 5000), isTrue);
    });
  });

  group('UserNote.clampedTo', () {
    final note = UserNote(id: 'n', timestampMs: 9000, kind: UserNoteKind.text, text: '晚了', createdAt: DateTime(2026));

    test('a note inside the recording is unchanged', () {
      expect(identical(note.clampedTo(9000), note), isTrue);
    });

    test('a note past the end moves to the end, keeping the rest', () {
      final clamped = note.clampedTo(7000);

      expect(clamped.timestampMs, 7000);
      expect(clamped.id, 'n');
      expect(clamped.text, '晚了');
    });
  });
}
