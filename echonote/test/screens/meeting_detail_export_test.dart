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
  _MemoryStore(this.recordings);
  final List<Recording> recordings;

  @override
  Future<List<Recording>> loadAll() async => recordings;

  @override
  Future<void> save(Recording recording) async {}

  @override
  Future<String> resolveAudioPath(Recording recording) async => '/missing/${recording.audioFileName}';
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

Future<void> _openMenu(WidgetTester tester, Recording recording, List<Recording> all, {
  Future<void> Function(String, String)? shareFile,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MeetingDetailScreen(
        recording: recording,
        store: _MemoryStore(all),
        glossary: _EmptyGlossary(),
        shareFile: shareFile,
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.byTooltip('更多'));
  await tester.pumpAndSettle();
}

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

  testWidgets('export writes the minutes and hands the file to the share sheet', (tester) async {
    final previous = _recording('m1', analysis: _analysis('第一次週會'));
    final current = _recording('m2', analysis: _analysis('官網改版週會'), previous: 'm1');
    final shared = Completer<(String, String)>();
    await _openMenu(tester, current, [current, previous], shareFile: (path, name) async => shared.complete((path, name)));

    await tester.tap(find.text('匯出會議紀錄'));
    await tester.pumpAndSettle();
    // The file write is real IO: let real time pass, then pump, until the
    // screen gets to the share call.
    for (var i = 0; i < 100 && !shared.isCompleted; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    final (path, name) = await shared.future;

    expect(name, '官網改版週會_2026-11-01.html');
    final html = (await tester.runAsync(() => File(path).readAsString()))!;
    expect(html, contains('<h1>官網改版週會</h1>'));
    expect(html, contains('接續：第一次週會（2026-11-01）'));
  });

  testWidgets('export is greyed out until the meeting is analyzed', (tester) async {
    var shared = false;
    final recording = _recording('m3');
    await _openMenu(tester, recording, [recording], shareFile: (_, _) async => shared = true);

    final item = tester.widget<PopupMenuItem<Object?>>(
      find.ancestor(of: find.text('匯出會議紀錄'), matching: find.byWidgetPredicate((w) => w is PopupMenuItem)),
    );
    expect(item.enabled, isFalse);
    await tester.tap(find.text('匯出會議紀錄'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(shared, isFalse);
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
}
