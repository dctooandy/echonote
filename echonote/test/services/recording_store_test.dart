import 'dart:convert';
import 'dart:io';

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
}
