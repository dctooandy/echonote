import 'dart:convert';
import 'dart:io';

import 'package:echonote/models/recording.dart';
import 'package:echonote/services/audio_duration_probe.dart';
import 'package:echonote/services/recording_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  late Directory dir;
  late File entry;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('recording_store_test');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    entry = File('${dir.path}/history/1.json');
  });

  tearDown(() => dir.delete(recursive: true));

  group('saveDuration', () {
    test('sets only the length, keeping what was saved meanwhile', () async {
      entry
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({
          'id': '1',
          'segments': [
            {'start_ms': 0, 'end_ms': 1500, 'text': '改過的字', 'edited': true},
          ],
          'future_field': 'kept',
        }));

      await RecordingStore().saveDuration('1', 2652000);

      expect(jsonDecode(entry.readAsStringSync()), {
        'id': '1',
        'segments': [
          {'start_ms': 0, 'end_ms': 1500, 'text': '改過的字', 'edited': true},
        ],
        'future_field': 'kept',
        'duration_ms': 2652000,
      });
    });

    test('a deleted entry stays deleted', () async {
      await RecordingStore().saveDuration('1', 1000);

      expect(entry.existsSync(), isFalse);
    });

    test('a corrupt entry is left as it is', () async {
      entry
        ..createSync(recursive: true)
        ..writeAsStringSync('{not json');

      await RecordingStore().saveDuration('1', 1000);

      expect(entry.readAsStringSync(), '{not json');
    });
  });

  test('a missing audio file has no length', () async {
    expect(await AudioDurationProbe().durationMs('${dir.path}/nope.m4a'), isNull);
  });

  group('save (spec fix-save-failure-notice)', () {
    Recording recording(String text) => Recording(
      id: '1',
      audioName: '1.m4a',
      createdAt: DateTime(2026, 11, 7),
      model: 'base',
      elapsedSeconds: 1,
      audioFileName: '1.m4a',
      segments: [TranscriptSegment(startMs: 0, endMs: 1000, text: text)],
    );

    String savedText() => ((jsonDecode(entry.readAsStringSync()) as Map)['segments'] as List).first['text'] as String;

    test('overlapping saves land in the order they were made', () async {
      final store = RecordingStore();
      await Future.wait([for (final text in ['一', '二', '三']) store.save(recording(text))]);
      expect(savedText(), '三');
      expect(Directory('${dir.path}/history').listSync().map((f) => f.path.split('/').last), ['1.json']);
    });

    test('the version made at the call is what gets saved', () async {
      final store = RecordingStore();
      final r = recording('存的時候');
      final saving = store.save(r);
      r.segments.first.text = '之後才改';
      await saving;
      expect(savedText(), '存的時候');
    });

    test('a failed save leaves the old file whole, and the next save still works', () async {
      final store = RecordingStore();
      await store.save(recording('舊的'));

      // A read-only folder: the temp file can't be created.
      final history = '${dir.path}/history';
      await Process.run('chmod', ['555', history]);
      addTearDown(() => Process.run('chmod', ['755', history]));
      await expectLater(store.save(recording('失敗的')), throwsA(isA<FileSystemException>()));
      expect(savedText(), '舊的');

      await Process.run('chmod', ['755', history]);
      await store.save(recording('新的'));
      expect(savedText(), '新的');
    });

    test('deleting after a save does not bring the entry back', () async {
      final store = RecordingStore();
      final r = recording('內容');
      await Future.wait([store.save(r), store.delete(r)]);
      expect(entry.existsSync(), isFalse);
    });
  });
}
