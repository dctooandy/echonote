import 'package:echonote/models/recording.dart';
import 'package:echonote/screens/line_message_screen.dart';
import 'package:echonote/services/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Recording _recording({List<String> decisions = const ['主色用藍色'], bool stale = false, String source = 'live'}) =>
    Recording.fromJson({
      ...Recording(
        id: '1',
        audioName: '1.m4a',
        createdAt: DateTime(2026, 11, 2),
        model: 'base',
        elapsedSeconds: 1,
        audioFileName: '1.m4a',
        segments: [TranscriptSegment(startMs: 0, endMs: 1000, text: '大家好')],
        analysis: MeetingAnalysis(
          overview: '摘要',
          keyPoints: const [],
          todos: [Todo(task: '提供推薦語', owner: '王經理', dueDate: '週五前')],
          title: '週會',
          attendees: const [],
          agendaItems: [AgendaItem(topic: '議題', discussion: '討論', decisions: decisions)],
        ),
        transcriptStaleAnalysis: stale,
      ).toJson(),
      'source': source,
    });

void main() {
  String? copied;

  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      },
    );
  });

  Future<void> pump(WidgetTester tester, Recording recording, AppSettings settings) async {
    await tester.pumpWidget(
      AppSettingsScope(
        settings: settings,
        child: MaterialApp(home: LineMessageScreen(recording: recording)),
      ),
    );
    await tester.pump();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets('shows the message, and copies what was edited', (tester) async {
    final settings = AppSettings(myName: 'Andy', lineGreetingName: '陳醫師');
    await pump(tester, _recording(), settings);

    expect(find.textContaining('（麻煩您）提供推薦語'), findsOneWidget);
    expect(tester.widget<TextField>(field('稱呼')).controller!.text, '陳醫師');

    await tester.enterText(find.byType(TextField).last, '改過的內容');
    await tester.tap(find.text('複製'));
    await tester.pump();

    expect(copied, '陳醫師好，今天會議的結論整理如下：\n\n改過的內容');
    expect(find.text('已複製到剪貼簿'), findsOneWidget);
  });

  testWidgets('changing the name keeps an edited body, and is remembered', (tester) async {
    final settings = AppSettings();
    await pump(tester, _recording(), settings);

    await tester.enterText(find.byType(TextField).last, '改過的內容');
    await tester.enterText(field('稱呼'), '王經理');
    await tester.tap(find.text('複製'));
    await tester.pump();

    expect(copied, '王經理好，今天會議的結論整理如下：\n\n改過的內容');
    expect(settings.lineGreetingName, '王經理');
  });

  testWidgets('no name, no greeting', (tester) async {
    await pump(tester, _recording(), AppSettings(myName: 'Andy'));
    await tester.tap(find.text('複製'));
    await tester.pump();
    expect(copied, startsWith('【您已決定的事項】'));
  });

  testWidgets('without attending, the name is not used', (tester) async {
    await pump(tester, _recording(source: 'import'), AppSettings(myName: 'Andy'));
    expect(find.textContaining('麻煩您'), findsNothing);
    expect(find.textContaining('提供推薦語（王經理）'), findsOneWidget);
  });

  testWidgets('a stale analysis warns but can still be copied', (tester) async {
    await pump(tester, _recording(stale: true), AppSettings());
    expect(find.textContaining('可能過時'), findsOneWidget);
    await tester.tap(find.text('複製'));
    await tester.pump();
    expect(copied, isNotNull);
  });

  testWidgets('nothing to say shows why, and cannot be copied', (tester) async {
    final recording = _recording(decisions: const []);
    recording.analysis!.todos.clear();
    await pump(tester, recording, AppSettings());
    expect(find.text('這場沒有整理出決定和待辦'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byWidgetPredicate((w) => w is FilledButton)).onPressed, isNull);
  });
}
