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

  group('series (spec feature-chain-links)', () {
    // Website weekly: w1 <- w2 <- w3, and w2 <- kick (a branch).
    // Trip: t1 <- t2. Alone: solo. Orphan follows a deleted meeting.
    final w1 = _r('w1', DateTime(2026, 10, 31));
    final w2 = _r('w2', DateTime(2026, 11, 1, 14), previous: 'w1');
    final kick = _r('kick', DateTime(2026, 11, 3), previous: 'w2');
    final w3 = _r('w3', DateTime(2026, 11, 8), previous: 'w2');
    final t1 = _r('t1', DateTime(2026, 10, 20));
    final t2 = _r('t2', DateTime(2026, 11, 1, 12), previous: 't1');
    final solo = _r('solo', DateTime(2026, 11, 1, 13));
    final orphan = _r('orphan', DateTime(2026, 11, 2), previous: 'gone');
    final all = [solo, w3, t2, w1, kick, orphan, w2, t1];

    test('followers are the meetings that follow it, oldest first', () {
      expect(followersOf(w2, all).map((r) => r.id), ['kick', 'w3']);
      expect(followersOf(w3, all), isEmpty);
    });

    test('series group linked meetings, newest first; lone meetings are left out', () {
      final series = seriesOf(all);
      expect(series.map((s) => s.recordings.map((r) => r.id).toList()), [
        ['w3', 'kick', 'w2', 'w1'],
        ['t2', 't1'],
      ]);
      expect(series.first.name, w3.displayTitle);
      expect(series.first.latest, DateTime(2026, 11, 8));
      expect(series.first.contains(kick), isTrue);
      expect(series.first.contains(solo), isFalse);
    });

    test('colors go by the age of the series, so new recordings never recolor one', () {
      final colors = {for (final s in seriesOf(all)) s.recordings.last.id: s.colorIndex};
      expect(colors, {'t1': 0, 'w1': 1});
      final later = [...all, _r('w4', DateTime(2026, 11, 15), previous: 'w3'), _r('n1', DateTime(2026, 11, 9)), _r('n2', DateTime(2026, 11, 10), previous: 'n1')];
      final again = {for (final s in seriesOf(later)) s.recordings.last.id: s.colorIndex};
      expect(again, {'t1': 0, 'w1': 1, 'n1': 2});
    });

    test('a deleted first meeting splits the series', () {
      final series = seriesOf(all.where((r) => r.id != 'w2').toList());
      expect(series.map((s) => s.recordings.map((r) => r.id).toList()), [
        ['t2', 't1'],
      ]);
    });

    test('the single view hint says what it follows and how many follow it', () {
      expect(chainHint(w2, all), '↩ 接續 10/31 · ↪ 2 場後續');
      expect(chainHint(w1, all), '↪ 1 場後續');
      expect(chainHint(w3, all), '↩ 接續 11/1');
      expect(chainHint(solo, all), isNull);
      expect(chainHint(orphan, all), isNull);
    });

    test('inside a frame, only a branch says what it follows', () {
      final website = seriesOf(all).first;
      expect([for (var i = 0; i < website.recordings.length; i++) seriesRowHint(website, i)], [
        '接續 11/1',
        null,
        null,
        null,
      ]);
    });
  });
}
