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
    // just_audio has no platform side in tests; answer its calls with null.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.just_audio.methods'),
      (_) async => null,
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
}
