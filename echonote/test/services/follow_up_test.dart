import 'package:echonote/models/recording.dart';
import 'package:echonote/services/analysis_service.dart';
import 'package:flutter_test/flutter_test.dart';

final _segments = [
  TranscriptSegment(startMs: 1000, endMs: 2000, text: '甲'),
  TranscriptSegment(startMs: 2000, endMs: 5000, text: '乙'),
];

void main() {
  group('resolveFollowUp', () {
    test('indices become the todo text and timestamps; unmentioned go last', () {
      final resolved = resolveFollowUp(
        {
          'todo_progress': [
            {'previous_todo_index': 1, 'status': 'not_mentioned', 'note': '沒提到', 'source_segment_index': null},
            {'previous_todo_index': 0, 'status': 'done', 'note': '已上線', 'source_segment_index': 1},
            {'previous_todo_index': 2, 'status': 'in_progress', 'note': '進行中', 'source_segment_index': 99},
          ],
          'decision_changes': [
            {'change': 'reversed', 'previous_decision': '11 月上線', 'current': '延到 12 月', 'source_segment_index': 0},
          ],
          'new_topics': ['預算', ' '],
        },
        _segments,
        ['寫測試', '訂場地', '找廠商'],
      );

      expect(resolved['todo_progress'], [
        {'task': '寫測試', 'status': 'done', 'note': '已上線', 'source_timestamp_ms': 2000},
        {'task': '找廠商', 'status': 'in_progress', 'note': '進行中', 'source_timestamp_ms': null},
        {'task': '訂場地', 'status': 'not_mentioned', 'note': '沒提到', 'source_timestamp_ms': null},
      ]);
      expect(resolved['decision_changes'], [
        {'change': 'reversed', 'previous_decision': '11 月上線', 'current': '延到 12 月', 'source_timestamp_ms': 1000},
      ]);
      expect(resolved['new_topics'], ['預算']);
    });

    test('unknown or repeated todo indices are dropped', () {
      final resolved = resolveFollowUp(
        {
          'todo_progress': [
            {'previous_todo_index': 5, 'status': 'done', 'note': '', 'source_segment_index': 0},
            {'previous_todo_index': 0, 'status': 'done', 'note': 'a', 'source_segment_index': 0},
            {'previous_todo_index': 0, 'status': 'in_progress', 'note': 'b', 'source_segment_index': 0},
          ],
        },
        _segments,
        ['寫測試'],
      );
      expect((resolved['todo_progress'] as List).single, containsPair('note', 'a'));
    });

    test('missing or malformed follow_up resolves to empty', () {
      for (final raw in [null, 'oops', <String, dynamic>{}]) {
        final followUp = FollowUp.fromJson(resolveFollowUp(raw, _segments, const []));
        expect(followUp.isEmpty, isTrue);
      }
    });
  });

  group('MeetingAnalysis follow_up JSON', () {
    Map<String, dynamic> base() => {
      'summary': {'overview': 'o', 'key_points': <String>[]},
      'todos': <dynamic>[],
      'structured_minutes': {'title': 't', 'attendees': <String>[], 'agenda_items': <dynamic>[]},
      'highlight_contexts': <String, String>{},
    };

    test('an analysis from before follow_up existed reads as empty and saves without it', () {
      final analysis = MeetingAnalysis.fromJson(base());
      expect(analysis.followUp.isEmpty, isTrue);
      expect(analysis.toJson().containsKey('follow_up'), isFalse);
    });

    test('follow_up round-trips', () {
      final json = base()
        ..['follow_up'] = {
          'todo_progress': [
            {'task': '寫測試', 'status': 'in_progress', 'note': 'n', 'source_timestamp_ms': 2000},
          ],
          'decision_changes': [
            {'change': 'revised', 'previous_decision': 'p', 'current': 'c', 'source_timestamp_ms': null},
          ],
          'new_topics': ['預算'],
        };
      final followUp = MeetingAnalysis.fromJson(MeetingAnalysis.fromJson(json).toJson()).followUp;

      expect(followUp.todoProgress.single.status, TodoProgressStatus.inProgress);
      expect(followUp.todoProgress.single.sourceTimestampMs, 2000);
      expect(followUp.decisionChanges.single.change, DecisionChangeKind.revised);
      expect(followUp.newTopics, ['預算']);
    });
  });
}
