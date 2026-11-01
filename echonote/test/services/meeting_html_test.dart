import 'package:echonote/models/recording.dart';
import 'package:echonote/services/meeting_html.dart';
import 'package:flutter_test/flutter_test.dart';

MeetingAnalysis _analysis({
  FollowUp? followUp,
  List<Todo>? todos,
  List<AgendaItem>? agenda,
}) => MeetingAnalysis(
  overview: '本週檢視進度',
  keyPoints: ['上線改到 11/22'],
  todos:
      todos ??
      [
        Todo(task: '寫 FAQ', owner: '小華', dueDate: '下週'),
        Todo(task: '告知超支', done: true),
      ],
  title: '官網改版週會',
  attendees: ['小明', '小華'],
  agendaItems:
      agenda ??
      [
        AgendaItem(
          topic: '主色',
          discussion: '藍色像銀行',
          decisions: ['改成綠色'],
          sourceTimestampMs: 42000,
        ),
      ],
  highlightContexts: {'n1': 'AI 對筆記的補充'},
  followUp: followUp,
);

Recording _recording(
  MeetingAnalysis? analysis, {
  String audioName = 'rec.m4a',
}) => Recording(
  id: 'm2',
  audioName: audioName,
  createdAt: DateTime(2026, 11, 1, 14, 5),
  model: 'base',
  elapsedSeconds: 1,
  audioFileName: 'm2.m4a',
  segments: [TranscriptSegment(startMs: 0, endMs: 1000, text: '逐字稿第一句')],
  analysis: analysis,
  durationMs: 372000,
  notes: [
    UserNote(
      id: 'n1',
      timestampMs: 0,
      kind: UserNoteKind.text,
      createdAt: DateTime(2026),
      text: '要跟老闆確認底線',
    ),
  ],
);

final _followUp = FollowUp(
  todoProgress: [
    TodoProgress(task: '寫首頁文案', status: TodoProgressStatus.done, note: '已上傳'),
  ],
  decisionChanges: [
    DecisionChange(
      change: DecisionChangeKind.reversed,
      previousDecision: '主色藍色',
      current: '主色綠色',
    ),
  ],
  newTopics: ['FAQ 頁', '預算'],
);

final _previous = Recording(
  id: 'm1',
  audioName: 'm1.m4a',
  createdAt: DateTime(2026, 10, 31),
  model: 'base',
  elapsedSeconds: 1,
  audioFileName: 'm1.m4a',
  segments: const [],
  analysis: MeetingAnalysis(
    overview: '',
    keyPoints: const [],
    todos: const [],
    title: '第一次週會',
    attendees: const [],
    agendaItems: const [],
  ),
);

final _at = DateTime(2026, 11, 1, 18, 30);

void main() {
  test('the file has every section, in order, with the meeting details', () {
    final html = buildMeetingHtml(
      _recording(_analysis(followUp: _followUp)),
      previous: _previous,
      exportedAt: _at,
    );
    final order = [
      '<h1>官網改版週會</h1>',
      '摘要',
      '與上次相比',
      '待辦事項',
      '會議紀錄',
      '由 EchoNote 產生',
    ];
    final positions = order.map(html.indexOf).toList();
    expect(positions.every((p) => p >= 0), isTrue, reason: '$positions');
    expect(positions, orderedEquals([...positions]..sort()));
    expect(html, contains('2026-11-01（日）14:05'));
    expect(html, contains('6:12'));
    expect(html, contains('出席：小明、小華'));
    expect(html, contains('接續：第一次週會（2026-10-31）'));
    expect(html, contains('<span class="pill ok">已完成</span>'));
    expect(html, contains('<span class="pill no">推翻</span>'));
    expect(html, contains('上次：主色藍色'));
    expect(html, contains('FAQ 頁、預算'));
    expect(html, contains('決議：改成綠色'));
    expect(html, contains('2026-11-01 18:30'));
    expect(html, contains('請以實際討論為準'));
  });

  test('todos show their tick, owner and due date', () {
    final html = buildMeetingHtml(_recording(_analysis()), exportedAt: _at);
    expect(
      html,
      contains(
        '<span class="box">☐</span><div><div class="t">寫 FAQ</div><div class="m">小華 · 期限 下週</div>',
      ),
    );
    expect(
      html,
      contains(
        '<span class="box">☑</span><div><div class="t done">告知超支</div></div>',
      ),
    );
  });

  test(
    'empty sections are left out, and no previous meeting means no 接續 line',
    () {
      final html = buildMeetingHtml(
        _recording(_analysis(todos: [], agenda: [])),
        exportedAt: _at,
      );
      expect(html, isNot(contains('與上次相比')));
      expect(html, isNot(contains('待辦事項')));
      expect(html, isNot(contains('會議紀錄')));
      final withFollowUp = buildMeetingHtml(
        _recording(_analysis(followUp: _followUp)),
        exportedAt: _at,
      );
      expect(withFollowUp, contains('與上次相比'));
      expect(withFollowUp, isNot(contains('接續：')));
    },
  );

  test(
    'private notes, AI note contexts, the transcript and timestamps stay out',
    () {
      final html = buildMeetingHtml(
        _recording(_analysis(followUp: _followUp)),
        previous: _previous,
        exportedAt: _at,
      );
      expect(html, isNot(contains('要跟老闆確認底線')));
      expect(html, isNot(contains('AI 對筆記的補充')));
      expect(html, isNot(contains('逐字稿第一句')));
      expect(html, isNot(contains('00:42')));
    },
  );

  test('text is escaped and nothing loads from the network', () {
    final evil = _analysis(
      todos: [Todo(task: '<script>alert("x")</script> & \'q\'')],
      agenda: [
        AgendaItem(topic: '<img src=x>', discussion: '', decisions: const []),
      ],
    );
    final html = buildMeetingHtml(
      _recording(evil, audioName: 'a<b>'),
      exportedAt: _at,
    );
    expect(html, isNot(contains('<script>')));
    expect(html, isNot(contains('<img')));
    expect(
      html,
      contains(
        '&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;q&#39;',
      ),
    );
    expect(html, isNot(matches(RegExp(r'https?:|@import|url\('))));
  });

  test(
    'the copy text adds what changed since last time, only when there is a follow-up',
    () {
      expect(summaryCopyText(_analysis()), '本週檢視進度\n• 上線改到 11/22');
      expect(
        summaryCopyText(_analysis(followUp: _followUp)),
        '本週檢視進度\n• 上線改到 11/22\n\n與上次相比\n上次的待辦：\n• 寫首頁文案（已完成）\n'
        '決議的變化：\n• 主色藍色 → 主色綠色（推翻）\n新的主題：FAQ 頁、預算',
      );
    },
  );

  test(
    'the file name is the title and date, with unsafe characters replaced',
    () {
      expect(
        meetingHtmlFileName(_recording(_analysis())),
        '官網改版週會_2026-11-01.html',
      );
      final slashy = _analysis()..title = '設計/行銷: Q4';
      expect(
        meetingHtmlFileName(_recording(slashy)),
        '設計_行銷_ Q4_2026-11-01.html',
      );
    },
  );
}
