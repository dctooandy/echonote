import 'dart:async';
import 'dart:io';

import 'package:echonote/models/recording.dart';
import 'package:echonote/screens/meeting_detail_screen.dart';
import 'package:echonote/services/glossary_store.dart';
import 'package:echonote/services/recording_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);
  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

/// Real file IO doesn't finish under the widget tester's fake clock, so the
/// screen gets an in-memory store.
class _MemoryStore extends RecordingStore {
  _MemoryStore(this.recordings, {this.audioPath, this.failures = 0});
  final List<Recording> recordings;
  final String? audioPath;

  /// How many saves fail before they start working.
  int failures;
  int saves = 0;

  @override
  Future<List<Recording>> loadAll() async => recordings;

  @override
  Future<void> save(Recording recording) async {
    if (failures > 0) {
      failures--;
      throw const FileSystemException('disk full');
    }
    saves++;
  }

  @override
  Future<String> resolveAudioPath(Recording recording) async => audioPath ?? '/missing/${recording.audioFileName}';
}

class _EmptyGlossary extends GlossaryStore {
  @override
  Future<GlossaryLoadResult> load() async => GlossaryLoadResult([]);
}

MeetingAnalysis _analysis(String title) => MeetingAnalysis(
  overview: '本週檢視進度',
  keyPoints: ['上線改到 11/22'],
  todos: [Todo(task: '寫 FAQ', owner: '小華')],
  title: title,
  attendees: const [],
  agendaItems: const [],
  followUp: FollowUp(newTopics: ['FAQ 頁']),
);

Recording _recording(String id, {MeetingAnalysis? analysis, String? previous}) => Recording(
  id: id,
  audioName: '$id.m4a',
  createdAt: DateTime(2026, 11, 1, 14, 5),
  model: 'base',
  elapsedSeconds: 1,
  audioFileName: 'missing.m4a',
  segments: [TranscriptSegment(startMs: 0, endMs: 1000, text: '大家好')],
  analysis: analysis,
  previousRecordingId: previous,
);

typedef _Files = List<({String path, String name})>;

Future<void> _openShare(
  WidgetTester tester,
  Recording recording,
  List<Recording> all, {
  Future<void> Function(_Files)? shareFiles,
  Future<Uint8List> Function(String)? htmlToPdf,
  String? audioPath,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MeetingDetailScreen(
        recording: recording,
        store: _MemoryStore(all, audioPath: audioPath),
        glossary: _EmptyGlossary(),
        shareFiles: shareFiles,
        htmlToPdf: htmlToPdf,
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.byTooltip('分享'));
  await tester.pumpAndSettle();
}

/// The file writes are real IO: let real time pass, then pump, until the
/// screen gets to the share call.
Future<void> _waitFor(WidgetTester tester, Completer<Object?> done) async {
  for (var i = 0; i < 100 && !done.isCompleted; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

ListTile _row(WidgetTester tester, String label) =>
    tester.widget<ListTile>(find.ancestor(of: find.text(label), matching: find.byType(ListTile)));

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('export_test');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.just_audio.methods'),
      (_) async => <String, dynamic>{},
    );
  });

  tearDown(() => dir.delete(recursive: true));

  // spec feature-share.
  testWidgets('the minutes go out as a PDF made from the same HTML', (tester) async {
    final previous = _recording('m1', analysis: _analysis('第一次週會'));
    final current = _recording('m2', analysis: _analysis('官網改版週會'), previous: 'm1');
    final shared = Completer<_Files>();
    String? html;
    await _openShare(
      tester,
      current,
      [current, previous],
      shareFiles: (files) async => shared.complete(files),
      htmlToPdf: (h) async {
        html = h;
        return Uint8List.fromList([1, 2, 3]);
      },
    );

    await tester.tap(find.text('會議紀錄'));
    await tester.pumpAndSettle();
    await _waitFor(tester, shared);
    final files = await shared.future;

    expect(files.single.name, '官網改版週會_2026-11-01.pdf');
    expect(html, contains('<h1>官網改版週會</h1>'));
    expect(html, contains('接續：第一次週會（2026-11-01）'));
    expect(await tester.runAsync(() => File(files.single.path).readAsBytes()), [1, 2, 3]);
  });

  testWidgets('an out-of-date analysis asks before the minutes go out', (tester) async {
    final recording = _recording('m2', analysis: _analysis('週會'))..transcriptStaleAnalysis = true;
    var shared = false;
    await _openShare(
      tester,
      recording,
      [recording],
      shareFiles: (_) async => shared = true,
      htmlToPdf: (_) async => Uint8List(0),
    );
    await tester.tap(find.text('會議紀錄'));
    await tester.pumpAndSettle();

    expect(find.text('分析可能過時'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(shared, isFalse);
  });

  testWidgets('without an analysis, conclusions and minutes are off, full data is on', (tester) async {
    final recording = _recording('m3');
    await _openShare(tester, recording, [recording]);

    expect(_row(tester, '傳給對方的結論').enabled, isFalse);
    expect(_row(tester, '會議紀錄').enabled, isFalse);
    expect(_row(tester, '完整資料').enabled, isTrue);
  });

  testWidgets('with nothing to send, full data is off too', (tester) async {
    final recording = _recording('m3')..segments = [];
    await _openShare(tester, recording, [recording]);
    expect(_row(tester, '完整資料').enabled, isFalse);
    expect(find.text('沒有逐字稿，也找不到錄音檔'), findsOneWidget);
  });

  testWidgets('conclusions open the preview', (tester) async {
    final recording = _recording('m2', analysis: _analysis('週會'));
    await _openShare(tester, recording, [recording]);
    await tester.tap(find.text('傳給對方的結論'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '傳給對方的結論'), findsOneWidget);
  });

  testWidgets('the old ways in are gone', (tester) async {
    final recording = _recording('m2', analysis: _analysis('週會'));
    await tester.pumpWidget(
      MaterialApp(home: MeetingDetailScreen(recording: recording, store: _MemoryStore([recording]), glossary: _EmptyGlossary())),
    );
    await tester.pump();
    expect(find.byTooltip('匯出逐字稿'), findsNothing);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('匯出會議紀錄'), findsNothing);
    expect(find.text('複製成 LINE 訊息'), findsNothing);
  });

  group('full data', () {
    late String audioPath;

    setUp(() {
      audioPath = '${dir.path}/audio.m4a';
      File(audioPath).writeAsBytesSync(List.filled(2048, 0));
    });

    testWidgets('sends the transcript by default, with no notes', (tester) async {
      final recording = _recording('m2', analysis: _analysis('週會'));
      final shared = Completer<_Files>();
      await _openShare(tester, recording, [recording], audioPath: audioPath, shareFiles: (f) async => shared.complete(f));
      await tester.tap(find.text('完整資料'));
      await tester.pumpAndSettle();
      expect(find.text('2 KB，含所有發言'), findsOneWidget);

      await tester.tap(find.text('分享'));
      await tester.pumpAndSettle();
      await _waitFor(tester, shared);

      final files = await shared.future;
      expect(files.map((f) => f.name), ['週會.txt']);
      expect(await tester.runAsync(() => File(files.single.path).readAsString()), contains('大家好'));
    });

    testWidgets('adding the recording asks once more, then sends both', (tester) async {
      final recording = _recording('m2', analysis: _analysis('週會'));
      final shared = Completer<_Files>();
      await _openShare(tester, recording, [recording], audioPath: audioPath, shareFiles: (f) async => shared.complete(f));
      await tester.tap(find.text('完整資料'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('原始錄音'));
      await tester.pumpAndSettle();
      expect(find.text('要傳錄音嗎？'), findsNothing);

      await tester.tap(find.text('分享'));
      await tester.pumpAndSettle();
      expect(find.text('要傳錄音嗎？'), findsOneWidget);
      await tester.tap(find.text('確定要傳'));
      await tester.pumpAndSettle();
      await _waitFor(tester, shared);

      final files = await shared.future;
      expect(files.map((f) => f.name), ['週會.txt', '週會.m4a']);
      expect(files.last.path, audioPath);
    });

    testWidgets('cancelling the question sends nothing', (tester) async {
      final recording = _recording('m2', analysis: _analysis('週會'));
      var shared = false;
      await _openShare(tester, recording, [recording], audioPath: audioPath, shareFiles: (_) async => shared = true);
      await tester.tap(find.text('完整資料'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('原始錄音'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('分享'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(shared, isFalse);
    });

    testWidgets('a missing recording can\'t be ticked, and nothing ticked can\'t be sent', (tester) async {
      final recording = _recording('m2', analysis: _analysis('週會'));
      await _openShare(tester, recording, [recording]);
      await tester.tap(find.text('完整資料'));
      await tester.pumpAndSettle();
      expect(find.text('找不到錄音檔'), findsOneWidget);

      await tester.tap(find.widgetWithText(CheckboxListTile, '逐字稿'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.byWidgetPredicate((w) => w is FilledButton)).onPressed, isNull);
    });
  });

  testWidgets('copying the summary includes what changed since last time', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    final recording = _recording('m4', analysis: _analysis('週會'));
    await tester.pumpWidget(
      MaterialApp(home: MeetingDetailScreen(recording: recording, store: _MemoryStore([recording]), glossary: _EmptyGlossary())),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('複製摘要'));
    await tester.pump();
    expect(copied, contains('與上次相比'));
    expect(copied, contains('新的主題：FAQ 頁'));
  });

  testWidgets('a long press on the title renames the meeting; clearing goes back to the AI title', (tester) async {
    final recording = _recording('m5', analysis: _analysis('AI 標題'));
    await tester.pumpWidget(
      MaterialApp(home: MeetingDetailScreen(recording: recording, store: _MemoryStore([recording]), glossary: _EmptyGlossary())),
    );
    await tester.pump();

    await tester.longPress(find.descendant(of: find.byType(AppBar), matching: find.text('AI 標題')));
    await tester.pumpAndSettle();
    expect(find.text('清空就恢復成：AI 標題'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '我的名稱');
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();
    expect(recording.customTitle, '我的名稱');
    expect(find.text('我的名稱'), findsOneWidget, reason: 'the app bar');

    await tester.tap(find.text('紀錄'));
    await tester.pumpAndSettle();
    expect(find.text('我的名稱'), findsNWidgets(2), reason: 'the minutes heading too');

    await tester.longPress(find.descendant(of: find.byType(AppBar), matching: find.text('我的名稱')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();
    expect(recording.customTitle, isNull);
    expect(find.text('AI 標題'), findsNWidgets(2));
  });

  group('a failed save (spec fix-save-failure-notice)', () {
    Future<void> rename(WidgetTester tester, _MemoryStore store, Recording recording, String name) async {
      await tester.pumpWidget(
        MaterialApp(home: MeetingDetailScreen(recording: recording, store: store, glossary: _EmptyGlossary())),
      );
      await tester.pump();
      await tester.longPress(find.descendant(of: find.byType(AppBar), matching: find.text('週會')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), name);
      await tester.tap(find.text('儲存'));
      await tester.pumpAndSettle();
    }

    testWidgets('says so, and trying again saves it', (tester) async {
      final recording = _recording('m2', analysis: _analysis('週會'));
      final store = _MemoryStore([recording], failures: 1);
      await rename(tester, store, recording, '新名字');

      expect(find.text('存檔失敗，這次的修改還沒保存'), findsOneWidget);
      await tester.tap(find.text('再試一次'));
      await tester.pumpAndSettle();

      expect(store.saves, 1);
      expect(find.text('存檔失敗，這次的修改還沒保存'), findsNothing);
      expect(find.text('已保存'), findsOneWidget);
    });

    testWidgets('failing again says so again', (tester) async {
      final recording = _recording('m2', analysis: _analysis('週會'));
      final store = _MemoryStore([recording], failures: 2);
      await rename(tester, store, recording, '新名字');
      await tester.tap(find.text('再試一次'));
      await tester.pumpAndSettle();

      expect(store.saves, 0);
      expect(find.text('存檔失敗，這次的修改還沒保存'), findsOneWidget);
    });

    testWidgets('a good save says nothing', (tester) async {
      final recording = _recording('m2', analysis: _analysis('週會'));
      final store = _MemoryStore([recording]);
      await rename(tester, store, recording, '新名字');

      expect(store.saves, 1);
      expect(find.textContaining('存檔失敗'), findsNothing);
      expect(find.text('已保存'), findsNothing);
    });
  });
}
