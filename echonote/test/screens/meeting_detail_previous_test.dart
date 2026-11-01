import 'package:echonote/models/recording.dart';
import 'package:echonote/screens/meeting_detail_screen.dart';
import 'dart:async';

import 'package:echonote/services/analysis_service.dart';
import 'package:echonote/services/glossary_store.dart';
import 'package:echonote/services/recording_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real file IO doesn't finish under the widget tester's fake clock, so the
/// screen gets an in-memory store.
class _MemoryStore extends RecordingStore {
  _MemoryStore(List<Recording> recordings) : _recordings = {for (final r in recordings) r.id: r};
  final Map<String, Recording> _recordings;

  @override
  Future<List<Recording>> loadAll() async =>
      _recordings.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  @override
  Future<void> save(Recording recording) async => _recordings[recording.id] = recording;

  @override
  Future<String> resolveAudioPath(Recording recording) async => '/missing/${recording.audioFileName}';
}

/// Answers when the test completes [result], and records what it was sent.
class _FakeAnalysisService extends AnalysisService {
  final result = Completer<MeetingAnalysis>();
  List<Recording>? sentPrevious;

  @override
  Future<MeetingAnalysis> analyze(
    List<TranscriptSegment> segments, {
    List<String> glossary = const [],
    List<UserNote> notes = const [],
    List<Recording> previous = const [],
  }) {
    sentPrevious = previous;
    return result.future;
  }
}

class _EmptyGlossary extends GlossaryStore {
  @override
  Future<GlossaryLoadResult> load() async => GlossaryLoadResult([]);
}

MeetingAnalysis _analysis(String title) => MeetingAnalysis(
  overview: '摘要',
  keyPoints: const [],
  todos: [],
  title: title,
  attendees: const [],
  agendaItems: const [],
);

Recording _recording(String id, DateTime createdAt, {String? title, String? previous}) => Recording(
  id: id,
  audioName: '$id.m4a',
  createdAt: createdAt,
  model: 'base',
  elapsedSeconds: 1,
  audioFileName: 'missing.m4a',
  segments: [TranscriptSegment(startMs: 0, endMs: 1000, text: '大家好')],
  analysis: title == null ? null : _analysis(title),
  previousRecordingId: previous,
);

Future<void> _pump(
  WidgetTester tester,
  Recording recording,
  List<Recording> saved, {
  AnalysisService? analysisService,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MeetingDetailScreen(
        recording: recording,
        store: _MemoryStore(saved),
        analysisService: analysisService,
        glossary: _EmptyGlossary(),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('接續上一場'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.just_audio.methods'),
      (_) async => <String, dynamic>{},
    );
  });

  final older = _recording('older', DateTime(2026, 10, 1), title: '十月一日週會');
  final unanalyzed = _recording('unanalyzed', DateTime(2026, 10, 8));
  final later = _recording('later', DateTime(2026, 10, 30), title: '之後的會議');

  testWidgets('the picker lists only earlier meetings, unanalyzed ones disabled', (tester) async {
    final current = _recording('current', DateTime(2026, 10, 15), title: '這場');
    await _pump(tester, current, [older, unanalyzed, later, current]);
    await _openPicker(tester);

    expect(find.text('十月一日週會'), findsOneWidget);
    expect(find.text('之後的會議'), findsNothing);
    expect(find.text('2026-10-08 · 尚未分析'), findsOneWidget);
    final disabled = tester.widget<ListTile>(
      find.ancestor(of: find.text('2026-10-08 · 尚未分析'), matching: find.byType(ListTile)),
    );
    expect(disabled.enabled, isFalse);
    expect(find.text('取消接續'), findsNothing);
  });

  testWidgets('picking a meeting links it and marks the analysis stale', (tester) async {
    final current = _recording('current', DateTime(2026, 10, 15), title: '這場');
    await _pump(tester, current, [older, current]);
    expect(find.textContaining('接續：'), findsNothing);

    await _openPicker(tester);
    await tester.tap(find.text('十月一日週會'));
    await tester.pumpAndSettle();

    expect(current.previousRecordingId, 'older');
    expect(current.previousChangedSinceAnalysis, isTrue);
    expect(find.text('↩ 接續：十月一日週會'), findsOneWidget);
    expect(find.text('接續的會議變了，重新分析才會更新「與上次相比」'), findsOneWidget);
  });

  testWidgets('without an analysis, linking shows no stale banner', (tester) async {
    final current = _recording('current', DateTime(2026, 10, 15));
    await _pump(tester, current, [older, current]);

    await _openPicker(tester);
    await tester.tap(find.text('十月一日週會'));
    await tester.pumpAndSettle();

    expect(current.previousRecordingId, 'older');
    expect(current.previousChangedSinceAnalysis, isFalse);
  });

  testWidgets('cancelling the link from the picker asks first, then clears it', (tester) async {
    final current = _recording('current', DateTime(2026, 10, 15), title: '這場', previous: 'older');
    await _pump(tester, current, [older, current]);
    expect(find.text('↩ 接續：十月一日週會'), findsOneWidget);

    await _openPicker(tester);
    await tester.tap(find.text('取消接續'));
    await tester.pumpAndSettle();
    expect(find.text('取消接續？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消接續'));
    await tester.pumpAndSettle();

    expect(current.previousRecordingId, isNull);
    expect(current.previousChangedSinceAnalysis, isTrue);
    expect(find.textContaining('接續：'), findsNothing);
  });

  group('the chain card (spec feature-chain-links)', () {
    final middle = _recording('middle', DateTime(2026, 10, 15), title: '這場', previous: 'older');
    final next1 = _recording('next1', DateTime(2026, 10, 22), title: '十月廿二日週會', previous: 'middle');
    final next2 = _recording('next2', DateTime(2026, 10, 23), title: '專案會', previous: 'middle');

    testWidgets('shows on every tab, closed, with what it follows and how many follow it', (tester) async {
      await _pump(tester, middle, [older, middle, next1, next2]);
      const summary = '↩ 接續：十月一日週會 · ↪ 2 場後續';
      expect(find.text(summary), findsOneWidget);
      expect(find.text('專案會'), findsNothing);
      for (final tab in ['待辦', '逐字稿', '紀錄']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        expect(find.text(summary), findsOneWidget, reason: tab);
      }
    });

    testWidgets('opens to the previous meeting and every follower', (tester) async {
      await _pump(tester, middle, [older, middle, next1, next2]);
      await tester.tap(find.text('↩ 接續：十月一日週會 · ↪ 2 場後續'));
      await tester.pumpAndSettle();
      expect(find.text('上一場 · 2026-10-01'), findsOneWidget);
      expect(find.text('十月廿二日週會'), findsOneWidget);
      expect(find.text('專案會'), findsOneWidget);
      expect(find.text('後續 · 2026-10-23'), findsOneWidget);
    });

    testWidgets('unlinking asks first; keeping it changes nothing', (tester) async {
      final current = _recording('current', DateTime(2026, 10, 15), title: '這場', previous: 'older');
      await _pump(tester, current, [older, current]);
      await tester.tap(find.text('↩ 接續：十月一日週會'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('取消接續'));
      await tester.pumpAndSettle();
      expect(find.textContaining('「十月一日週會（2026-10-01）」'), findsOneWidget);
      expect(find.textContaining('不會刪除錄音'), findsOneWidget);
      await tester.tap(find.text('保留'));
      await tester.pumpAndSettle();
      expect(current.previousRecordingId, 'older');
      expect(current.previousChangedSinceAnalysis, isFalse);

      await tester.tap(find.byTooltip('取消接續'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消接續'));
      await tester.pumpAndSettle();
      expect(current.previousRecordingId, isNull);
      expect(current.previousChangedSinceAnalysis, isTrue);
      expect(find.textContaining('接續：'), findsNothing);
    });

    testWidgets('a meeting with no links has no card', (tester) async {
      final alone = _recording('alone', DateTime(2026, 10, 15), title: '這場');
      await _pump(tester, alone, [older, alone]);
      expect(find.textContaining('接續'), findsNothing);
      expect(find.textContaining('場後續'), findsNothing);
    });
  });

  testWidgets('a deleted previous meeting says so', (tester) async {
    final current = _recording('current', DateTime(2026, 10, 15), title: '這場', previous: 'gone');
    await _pump(tester, current, [current]);

    expect(find.text('接續的會議已刪除'), findsOneWidget);
    expect(current.previousRecordingId, 'gone');
  });

  testWidgets('no follow-up, no comparison card', (tester) async {
    final current = _recording('current', DateTime(2026, 10, 15), title: '這場');
    await _pump(tester, current, [current]);

    expect(find.byTooltip('複製摘要'), findsOneWidget);
    expect(find.text('與上次相比'), findsNothing);
  });

  testWidgets('the comparison card shows the three parts and seeks on tap', (tester) async {
    final analysis = MeetingAnalysis(
      overview: '摘要',
      keyPoints: const [],
      todos: [],
      title: '這場',
      attendees: const [],
      agendaItems: const [],
      followUp: FollowUp(
        todoProgress: [
          TodoProgress(task: '寫測試', status: TodoProgressStatus.done, note: '已經寫完', sourceTimestampMs: 65000),
          TodoProgress(task: '訂場地', status: TodoProgressStatus.notMentioned, note: ''),
        ],
        decisionChanges: [
          DecisionChange(
            change: DecisionChangeKind.reversed,
            previousDecision: '11 月上線',
            current: '延到 12 月',
          ),
        ],
        newTopics: ['預算'],
      ),
    );
    final current = _recording('current', DateTime(2026, 10, 15), previous: 'older')..analysis = analysis;
    await _pump(tester, current, [older, current]);

    expect(find.text('與上次相比'), findsOneWidget);
    expect(find.text('上次的待辦'), findsOneWidget);
    expect(find.text('已完成　寫測試', findRichText: true), findsOneWidget);
    expect(find.text('這次沒提到　訂場地', findRichText: true), findsOneWidget);
    expect(find.text('已經寫完'), findsOneWidget);
    expect(find.text('01:05'), findsOneWidget);
    expect(find.text('決議的變化'), findsOneWidget);
    expect(find.text('推翻　延到 12 月', findRichText: true), findsOneWidget);
    expect(find.text('上次：11 月上線'), findsOneWidget);
    expect(find.text('• 預算'), findsOneWidget);
  });

  group('re-analysis', () {
    setUp(() => AnalysisService.available = true);
    tearDown(() => AnalysisService.available = false);

    Future<_FakeAnalysisService> startReanalysis(WidgetTester tester, Recording current, List<Recording> saved) async {
      final service = _FakeAnalysisService();
      await _pump(tester, current, saved, analysisService: service);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      // .last: the menu sits above the stale banner's own 重新分析 button.
      await tester.tap(find.text('重新分析').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '重新分析'));
      await tester.pump();
      return service;
    }

    testWidgets('shows what is running and for how long, then says it is done', (tester) async {
      final current = _recording('current', DateTime(2026, 10, 15), title: '這場', previous: 'older')
        ..previousChangedSinceAnalysis = true;
      final service = await startReanalysis(tester, current, [older, current]);

      expect(find.text('正在重新分析…'), findsOneWidget);
      expect(find.text('已 0:00'), findsOneWidget);
      expect(find.text('通常需要半分鐘，可以先看其他分頁'), findsOneWidget);
      // The stale banner steps aside while the fix for it is running.
      expect(find.textContaining('接續的會議變了'), findsNothing);
      expect(service.sentPrevious?.map((r) => r.id), ['older']);

      await tester.pump(const Duration(seconds: 3));
      expect(find.text('已 0:03'), findsOneWidget);

      service.result.complete(_analysis('新的標題'));
      await tester.pumpAndSettle();

      expect(find.text('正在重新分析…'), findsNothing);
      expect(find.text('分析完成，內容已更新'), findsOneWidget);
      expect(current.analysis?.title, '新的標題');
      expect(current.previousChangedSinceAnalysis, isFalse);
    });

    testWidgets('a failure removes the banner and says why', (tester) async {
      final current = _recording('current', DateTime(2026, 10, 15), title: '這場');
      final service = await startReanalysis(tester, current, [current]);

      service.result.completeError(StateError('boom'));
      await tester.pumpAndSettle();

      expect(find.text('正在重新分析…'), findsNothing);
      expect(find.text('分析失敗：Bad state: boom'), findsOneWidget);
      expect(current.analysis?.title, '這場');
    });
  });
}
