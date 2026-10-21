import 'dart:io';

import 'package:echonote/models/recording.dart';
import 'package:echonote/screens/meeting_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      Directory.systemTemp.createTempSync('echonote_notes_test').path;
}

Recording _recording() => Recording(
  id: '1',
  audioName: '會議.m4a',
  createdAt: DateTime(2026, 10, 21),
  model: 'base',
  elapsedSeconds: 1,
  audioFileName: 'missing.m4a',
  segments: [TranscriptSegment(startMs: 0, endMs: 1000, text: '大家好')],
  notes: [
    UserNote(
      id: 'n1',
      timestampMs: 65000,
      kind: UserNoteKind.text,
      text: '報價要再確認',
      createdAt: DateTime(2026, 10, 21),
    ),
  ],
);

Future<void> _pump(WidgetTester tester, Recording recording) async {
  await tester.pumpWidget(MaterialApp(home: MeetingDetailScreen(recording: recording)));
  await tester.pump();
}

void main() {
  setUpAll(() {
    PathProviderPlatform.instance = _FakePathProviderPlatform();
  });

  setUp(() {
    // just_audio has no platform side in tests; answer its calls with an
    // empty result.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.just_audio.methods'),
      (_) async => <String, dynamic>{},
    );
  });

  testWidgets('notes show above the summary before any analysis', (tester) async {
    await _pump(tester, _recording());

    expect(find.text('你的重點'), findsOneWidget);
    expect(find.text('報價要再確認'), findsOneWidget);
    expect(find.text('01:05'), findsOneWidget);
    expect(find.text('尚未產出摘要/待辦/結構化紀錄'), findsOneWidget);
  });

  testWidgets('no notes, no section', (tester) async {
    await _pump(tester, _recording()..notes.clear());

    expect(find.text('你的重點'), findsNothing);
  });

  testWidgets('★ adds a mark once per second', (tester) async {
    final recording = _recording()..notes.clear();
    await _pump(tester, recording);

    await tester.tap(find.byTooltip('標記重點'));
    await tester.tap(find.byTooltip('標記重點'));
    await tester.pump();

    expect(recording.notes.single.kind, UserNoteKind.star);
    expect(find.text('重點標記'), findsOneWidget);
  });

  testWidgets('deleting a note can be undone, with its AI context', (tester) async {
    final recording = _recording()
      ..analysis = MeetingAnalysis(
        overview: '概要',
        keyPoints: [],
        todos: [],
        title: '',
        attendees: [],
        agendaItems: [],
        highlightContexts: {'n1': '討論報價'},
      );
    await _pump(tester, recording);

    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, '報價要再確認'),
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('刪除'));
    await tester.pumpAndSettle();

    expect(recording.notes, isEmpty);
    expect(recording.analysis!.highlightContexts, isEmpty);

    await tester.tap(find.text('復原'));
    await tester.pump();

    expect(recording.notes.single.id, 'n1');
    expect(recording.analysis!.highlightContexts, {'n1': '討論報價'});
  });

  MeetingAnalysis analysis({Map<String, String>? contexts}) => MeetingAnalysis(
    overview: '概要',
    keyPoints: [],
    todos: [],
    title: '',
    attendees: [],
    agendaItems: [],
    highlightContexts: contexts,
  );

  testWidgets('AI context shows under the note it belongs to', (tester) async {
    await _pump(tester, _recording()..analysis = analysis(contexts: {'n1': '討論報價'}));

    expect(find.text('報價要再確認'), findsOneWidget);
    expect(find.text('討論報價'), findsOneWidget);
    expect(find.textContaining('還沒有 AI 補充說明'), findsNothing);
  });

  testWidgets('notes without AI context prompt a re-analysis', (tester) async {
    await _pump(tester, _recording()..analysis = analysis());

    expect(find.text('有 1 筆重點還沒有 AI 補充說明，重新分析可補上'), findsOneWidget);
  });

  testWidgets('no hint before the first analysis', (tester) async {
    await _pump(tester, _recording());

    expect(find.textContaining('還沒有 AI 補充說明'), findsNothing);
  });

  testWidgets('transcript marks the line a note falls on', (tester) async {
    final recording = _recording()
      ..segments.add(TranscriptSegment(startMs: 60000, endMs: 70000, text: '報價的部分'));
    await _pump(tester, recording);

    await tester.tap(find.text('逐字稿'));
    await tester.pumpAndSettle();

    // The note at 01:05 falls in the segment starting at 01:00.
    final marked = find.widgetWithText(ListTile, '報價的部分');
    expect(find.descendant(of: marked, matching: find.byIcon(Icons.notes)), findsOneWidget);
    final unmarked = find.widgetWithText(ListTile, '大家好');
    expect(find.descendant(of: unmarked, matching: find.byIcon(Icons.notes)), findsNothing);
  });

  testWidgets('stale analysis shows a banner on every tab', (tester) async {
    await _pump(tester, _recording()
      ..analysis = analysis()
      ..transcriptStaleAnalysis = true);

    expect(find.text('逐字稿已更新，分析結果可能過時'), findsOneWidget);
    await tester.tap(find.text('待辦'));
    await tester.pumpAndSettle();
    expect(find.text('逐字稿已更新，分析結果可能過時'), findsOneWidget);
  });

  testWidgets('no banner when the analysis is current', (tester) async {
    await _pump(tester, _recording()..analysis = analysis());

    expect(find.text('逐字稿已更新，分析結果可能過時'), findsNothing);
  });

  testWidgets('re-transcribe warns about edited lines and can be cancelled', (tester) async {
    final recording = _recording()..analysis = analysis();
    recording.segments.single
      ..text = '大家早'
      ..edited = true;
    await _pump(tester, recording);

    await tester.tap(find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.more_vert)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('用目前詞庫重新轉錄'));
    await tester.pumpAndSettle();

    expect(find.textContaining('你修改過的 1 處逐字稿會被覆蓋'), findsOneWidget);
    expect(find.textContaining('分析結果會保留'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(recording.segments.single.text, '大家早');
  });

  testWidgets('untranscribed recordings have no re-transcribe menu item', (tester) async {
    await _pump(tester, _recording()..segments.clear());

    await tester.tap(find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.more_vert)));
    await tester.pumpAndSettle();

    expect(find.text('用目前詞庫重新轉錄'), findsNothing);
  });

  testWidgets('long-pressing a transcript line edits it', (tester) async {
    final recording = _recording();
    await _pump(tester, recording);
    await tester.tap(find.text('逐字稿'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('大家好'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), ' 大家早 ');
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();

    expect(recording.segments.single.text, '大家早');
    expect(recording.segments.single.edited, isTrue);
    expect(find.text('大家早'), findsOneWidget);
  });

  testWidgets('saving an unchanged line does not mark it edited', (tester) async {
    final recording = _recording();
    await _pump(tester, recording);
    await tester.tap(find.text('逐字稿'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('大家好'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();

    expect(recording.segments.single.edited, isFalse);
  });

  Future<void> correct(WidgetTester tester, String line, String corrected) async {
    await tester.tap(find.text('逐字稿'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text(line));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), corrected);
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();
  }

  Recording withLines(List<String> lines) => _recording()
    ..segments
        .replaceRange(0, 1, [for (final (i, l) in lines.indexed) TranscriptSegment(startMs: i * 1000, endMs: i * 1000 + 999, text: l)]);

  testWidgets('a correction offers to learn the widened term and fix the rest', (tester) async {
    final recording = withLines(['太基電的報價', '太基電回覆了', '跟太基電談']);
    recording.analysis = analysis();
    await _pump(tester, recording);

    await correct(tester, '太基電的報價', '台積電的報價');
    expect(find.text('會把「太基」記成「台積」'), findsOneWidget);

    // The detected span is half the word; the user completes it.
    await tester.enterText(find.widgetWithText(TextField, '台積'), '台積電');
    await tester.pumpAndSettle();
    expect(find.text('會把「太基電」記成「台積電」'), findsOneWidget);
    expect(find.text('加入並修正 2 處'), findsOneWidget);

    await tester.tap(find.text('加入並修正 2 處'));
    // The glossary is read and written with real file I/O, which fake time
    // doesn't advance: let real time pass between pumps until it's done.
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await tester.pumpAndSettle();

    expect(recording.segments.map((s) => s.text), ['台積電的報價', '台積電回覆了', '跟台積電談']);
    expect(recording.transcriptStaleAnalysis, isTrue);
    expect(find.text('已加入詞庫，並修正 2 處'), findsOneWidget);
  });

  testWidgets('a declined replacement is not offered again in this recording', (tester) async {
    final recording = withLines(['太基電的報價', '太基電回覆了']);
    await _pump(tester, recording);

    await correct(tester, '太基電的報價', '台積電的報價');
    await tester.tap(find.text('不用'));
    await tester.pumpAndSettle();
    expect(recording.dismissedReplacements, ['太基→台積']);

    await correct(tester, '太基電回覆了', '台積電回覆了');
    expect(find.text('記住這個寫法？'), findsNothing);
  });

  testWidgets('a single-character fix asks nothing', (tester) async {
    await _pump(tester, withLines(['他說好']));

    await correct(tester, '他說好', '她說好');

    expect(find.text('記住這個寫法？'), findsNothing);
  });
}
