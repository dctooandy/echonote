import 'dart:convert';
import 'dart:io';

import 'package:echonote/models/recording.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/export_eval_case.dart';

Recording _meeting(String id, DateTime createdAt, {String? title, String? previous, List<UserNote>? notes}) => Recording(
  id: id,
  audioName: '即時錄音 $id',
  createdAt: createdAt,
  model: 'base',
  elapsedSeconds: 1,
  audioFileName: '$id.wav',
  segments: [
    TranscriptSegment(startMs: 0, endMs: 1000, text: '開始'),
    TranscriptSegment(startMs: 1000, endMs: 5000, text: '討論'),
  ],
  analysis: title == null
      ? null
      : MeetingAnalysis(
          overview: '$title 的摘要',
          keyPoints: const [],
          todos: [Todo(task: '寫文案', owner: '小明', done: true)],
          title: title,
          attendees: const ['不該送出'],
          agendaItems: [AgendaItem(topic: 't', discussion: 'd', decisions: ['11 月上線'])],
        ),
  notes: notes,
  previousRecordingId: previous,
);

/// A fake downloaded container: `<tmp>/AppData/Documents/{history,glossary.json}`.
String _container(List<Recording> recordings, {List<String> glossary = const []}) {
  final root = Directory.systemTemp.createTempSync('echonote_export_test').path;
  final history = Directory('$root/AppData/Documents/history')..createSync(recursive: true);
  for (final r in recordings) {
    File('${history.path}/${r.id}.json').writeAsStringSync(jsonEncode(r.toJson()));
  }
  File('$root/AppData/Documents/glossary.json').writeAsStringSync(jsonEncode({
    'version': 1,
    'terms': [
      for (final (i, term) in glossary.indexed)
        {'id': '$i', 'term': term, 'created_at': DateTime(2026, 11).toIso8601String()},
    ],
  }));
  return root;
}

void main() {
  final first = _meeting('1', DateTime(2026, 10, 24), title: '官網改版週會');
  final second = _meeting(
    '2',
    DateTime(2026, 10, 31),
    previous: '1',
    notes: [
      UserNote(id: 'n', timestampMs: 2000, kind: UserNoteKind.text, text: '決定改去花蓮', createdAt: DateTime(2026, 10, 31)),
    ],
  );

  test('a .xcappdata or its Documents folder both work', () {
    final root = _container([first]);
    expect(documentsIn(root).path, '$root/AppData/Documents');
    expect(documentsIn('$root/AppData/Documents').path, '$root/AppData/Documents');
    expect(() => documentsIn(Directory.systemTemp.path), throwsA(isA<ExportException>()));
  });

  test('builds what the app sends, with the previous meeting frozen in', () {
    final docs = documentsIn(_container([first, second], glossary: ['Riverpod']));
    final request = exportEvalCase(docs, '即時錄音 2', withGlossary: false);

    expect((request['segments'] as List).first, {'start_ms': 0, 'end_ms': 1000, 'text': '開始', 'edited': false});
    expect(request.containsKey('glossary'), isFalse);
    expect(request['highlights'], [
      {'note_index': 0, 'segment_index': 1, 'text': '決定改去花蓮'},
    ]);
    expect(request['previous_meetings'], [
      {
        'title': '官網改版週會',
        'date': '2026-10-24',
        'overview': '官網改版週會 的摘要',
        'decisions': ['11 月上線'],
        'todos': [
          {'task': '寫文案', 'owner': '小明', 'done': true},
        ],
      },
    ]);
  });

  test('the glossary goes in only when asked', () {
    final docs = documentsIn(_container([first], glossary: ['Riverpod', '蔡宜蓁']));
    expect(exportEvalCase(docs, '官網', withGlossary: true)['glossary'], ['Riverpod', '蔡宜蓁']);
    expect(exportEvalCase(docs, '官網', withGlossary: false).containsKey('glossary'), isFalse);
  });

  test('meetings are found by id, title or recording name, and must be unique', () {
    final docs = documentsIn(_container([first, second]));
    expect(exportEvalCase(docs, '1', withGlossary: false).containsKey('previous_meetings'), isFalse);
    expect(() => exportEvalCase(docs, '即時錄音', withGlossary: false),
        throwsA(isA<ExportException>().having((e) => e.message, 'message', contains('對到 2 場'))));
    expect(() => exportEvalCase(docs, '不存在', withGlossary: false),
        throwsA(isA<ExportException>().having((e) => e.message, 'message', contains('找不到'))));
  });

  test('an untranscribed meeting is refused', () {
    final empty = _meeting('3', DateTime(2026, 11, 1))..segments = [];
    final docs = documentsIn(_container([empty]));
    expect(() => exportEvalCase(docs, '3', withGlossary: false),
        throwsA(isA<ExportException>().having((e) => e.message, 'message', contains('還沒轉錄'))));
  });
}
