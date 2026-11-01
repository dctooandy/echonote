import 'package:echonote/models/recording.dart';
import 'package:echonote/screens/meeting_detail_screen.dart';
import 'package:echonote/services/glossary_store.dart';
import 'package:echonote/services/recording_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real file IO doesn't finish under the widget tester's fake clock, so the
/// screen gets an in-memory store.
class _MemoryStore extends RecordingStore {
  final saved = <String, Recording>{};

  @override
  Future<List<Recording>> loadAll() async => saved.values.toList();

  @override
  Future<void> save(Recording recording) async => saved[recording.id] = recording;

  @override
  Future<String> resolveAudioPath(Recording recording) async => '/missing/${recording.audioFileName}';
}

class _EmptyGlossary extends GlossaryStore {
  @override
  Future<GlossaryLoadResult> load() async => GlossaryLoadResult([]);
}

Recording _recording() => Recording(
  id: 'm1',
  audioName: 'm1.m4a',
  createdAt: DateTime(2026, 11, 1),
  model: 'base',
  elapsedSeconds: 60,
  audioFileName: 'missing.m4a',
  segments: [TranscriptSegment(startMs: 0, endMs: 1000, text: '大家好')],
  analysis: MeetingAnalysis(
    overview: '摘要',
    keyPoints: const [],
    todos: [
      Todo(task: '尋找三間民宿比較', owner: '小美', dueDate: '本週', sourceTimestampMs: 42000),
      Todo(task: '詢問遊覽車報價', owner: '阿傑'),
    ],
    title: '員工旅遊',
    attendees: const [],
    agendaItems: const [],
  ),
);

Future<_MemoryStore> _openTodos(WidgetTester tester, Recording recording) async {
  final store = _MemoryStore();
  await tester.pumpWidget(
    MaterialApp(
      home: MeetingDetailScreen(recording: recording, store: store, glossary: _EmptyGlossary()),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('待辦'));
  await tester.pumpAndSettle();
  return store;
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.just_audio.methods'),
      (_) async => <String, dynamic>{},
    );
  });

  testWidgets('deleting a todo asks first, and cancelling keeps it', (tester) async {
    final recording = _recording();
    final store = await _openTodos(tester, recording);

    await tester.tap(find.byTooltip('刪除待辦').first);
    await tester.pumpAndSettle();
    expect(find.text('刪除這筆待辦？'), findsOneWidget);
    expect(find.textContaining('「尋找三間民宿比較」'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(recording.analysis!.todos, hasLength(2));
    expect(find.text('尋找三間民宿比較'), findsOneWidget);
    expect(store.saved, isEmpty);

    await tester.tap(find.byTooltip('刪除待辦').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '刪除'));
    await tester.pumpAndSettle();
    expect(recording.analysis!.todos.map((t) => t.task), ['詢問遊覽車報價']);
    expect(find.text('尋找三間民宿比較'), findsNothing);
    expect(store.saved['m1']!.analysis!.todos, hasLength(1));
  });

  testWidgets('the task is 18pt and has its own line above the actions', (tester) async {
    await _openTodos(tester, _recording());

    final task = find.text('尋找三間民宿比較');
    expect(tester.widget<Text>(task).style?.fontSize, 18);
    final taskBox = tester.getRect(task);
    for (final tooltip in ['編輯待辦', '刪除待辦']) {
      expect(tester.getRect(find.byTooltip(tooltip).first).top, greaterThanOrEqualTo(taskBox.bottom), reason: tooltip);
    }
    expect(tester.getRect(find.text('00:42')).top, greaterThanOrEqualTo(taskBox.bottom));
    expect(find.text('小美 · 期限 本週'), findsOneWidget);
    expect(find.text('阿傑'), findsOneWidget);
  });
}
