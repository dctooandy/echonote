import 'package:echonote/models/recording.dart';
import 'package:echonote/services/meeting_chain.dart';
import 'package:echonote/utils/format.dart';
import 'package:flutter_test/flutter_test.dart';

MeetingAnalysis _analysis({
  String overview = '摘要',
  List<AgendaItem> agendaItems = const [],
  List<Todo>? todos,
}) => MeetingAnalysis(
  overview: overview,
  keyPoints: const [],
  todos: todos ?? [],
  title: '',
  attendees: const ['不該送出的人'],
  agendaItems: agendaItems,
);

Recording _r(String id, DateTime createdAt, {String? previous, MeetingAnalysis? analysis}) => Recording(
  id: id,
  audioName: '$id.m4a',
  createdAt: createdAt,
  model: 'base',
  elapsedSeconds: 0,
  audioFileName: '$id.m4a',
  segments: [],
  previousRecordingId: previous,
  analysis: analysis,
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

  group('previousChain', () {
    Recording analyzed(String id, int day, {String? previous}) =>
        _r(id, DateTime(2026, 10, day), previous: previous, analysis: _analysis());

    test('follows the links back, oldest first, at most 3', () {
      final m1 = analyzed('m1', 1);
      final m2 = analyzed('m2', 2, previous: 'm1');
      final m3 = analyzed('m3', 3, previous: 'm2');
      final m4 = analyzed('m4', 4, previous: 'm3');
      final now = analyzed('now', 5, previous: 'm4');
      expect(previousChain(now, [now, m4, m3, m2, m1]).map((r) => r.id), ['m2', 'm3', 'm4']);
      expect(previousChain(m3, [m3, m2, m1]).map((r) => r.id), ['m1', 'm2']);
    });

    test('stops at a deleted or unanalyzed meeting', () {
      final m1 = analyzed('m1', 1);
      final m2 = _r('m2', DateTime(2026, 10, 2), previous: 'm1');
      final m3 = analyzed('m3', 3, previous: 'm2');
      final now = analyzed('now', 4, previous: 'm3');
      expect(previousChain(now, [now, m3, m2, m1]).map((r) => r.id), ['m3']);

      final orphan = analyzed('orphan', 4, previous: 'gone');
      expect(previousChain(orphan, [orphan, m1]), isEmpty);
    });

    test('no link, no chain; a broken loop in the data does not hang', () {
      expect(previousChain(analyzed('x', 1), []), isEmpty);
      final a = analyzed('a', 1, previous: 'b');
      final b = analyzed('b', 2, previous: 'a');
      expect(previousChain(b, [a, b]).map((r) => r.id), ['a']);
    });
  });

  group('toPreviousMeetingPayload', () {
    test('sends title, date, overview, flattened decisions and todos with ticks — nothing else', () {
      final recording = _r(
        'p',
        DateTime(2026, 10, 24, 9),
        analysis: _analysis(
          agendaItems: [
            AgendaItem(topic: '時程', discussion: '…', decisions: ['11 月上線', ' ']),
            AgendaItem(topic: '人力', discussion: '…', decisions: ['加一位工程師']),
          ],
          todos: [Todo(task: '寫測試', owner: '小明', done: true), Todo(task: '訂場地')],
        ),
      )..analysis!.title = '週會';

      expect(toPreviousMeetingPayload(recording), {
        'title': '週會',
        'date': '2026-10-24',
        'overview': '摘要',
        'decisions': ['11 月上線', '加一位工程師'],
        'todos': [
          {'task': '寫測試', 'owner': '小明', 'done': true},
          {'task': '訂場地', 'owner': null, 'done': false},
        ],
      });
    });

    test('trims to the function\'s limits, counting a CJK character as one', () {
      final recording = _r(
        'p',
        DateTime(2026, 10, 24),
        analysis: _analysis(
          overview: '字' * (previousOverviewMaxChars + 10),
          agendaItems: [
            AgendaItem(
              topic: 't',
              discussion: 'd',
              decisions: List.generate(previousDecisionsMax + 5, (i) => '決' * (previousItemMaxChars + 1)),
            ),
          ],
          todos: List.generate(previousTodosMax + 5, (i) => Todo(task: '待' * (previousItemMaxChars + 1))),
        ),
      );
      final payload = toPreviousMeetingPayload(recording);

      expect((payload['overview'] as String).runes.length, previousOverviewMaxChars);
      expect(payload['decisions'] as List, hasLength(previousDecisionsMax));
      expect(((payload['decisions'] as List).first as String).runes.length, previousItemMaxChars);
      expect(payload['todos'] as List, hasLength(previousTodosMax));
      expect((((payload['todos'] as List).first as Map)['task'] as String).runes.length, previousItemMaxChars);
    });
  });
}
