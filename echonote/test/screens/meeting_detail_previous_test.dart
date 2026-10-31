import 'package:echonote/models/recording.dart';
import 'package:echonote/screens/meeting_detail_screen.dart';
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

Future<void> _pump(WidgetTester tester, Recording recording, List<Recording> saved) async {
  await tester.pumpWidget(
    MaterialApp(home: MeetingDetailScreen(recording: recording, store: _MemoryStore(saved))),
  );
  await tester.pump();
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byTooltip('接續上一場'));
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
    expect(find.text('接續：十月一日週會'), findsOneWidget);
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

  testWidgets('cancelling the link clears it', (tester) async {
    final current = _recording('current', DateTime(2026, 10, 15), title: '這場', previous: 'older');
    await _pump(tester, current, [older, current]);
    expect(find.text('接續：十月一日週會'), findsOneWidget);

    await _openPicker(tester);
    await tester.tap(find.text('取消接續'));
    await tester.pumpAndSettle();

    expect(current.previousRecordingId, isNull);
    expect(find.textContaining('接續：'), findsNothing);
  });

  testWidgets('a deleted previous meeting says so', (tester) async {
    final current = _recording('current', DateTime(2026, 10, 15), title: '這場', previous: 'gone');
    await _pump(tester, current, [current]);

    expect(find.text('接續的會議已刪除'), findsOneWidget);
    expect(current.previousRecordingId, 'gone');
  });
}
