import 'dart:io';

import 'package:echonote/models/recording.dart';
import 'package:echonote/services/glossary_store.dart';
import 'package:echonote/services/recording_store.dart';
import 'package:echonote/services/recording_transcriber.dart';
import 'package:echonote/services/transcription_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTranscription implements TranscriptionService {
  String? prompt;

  @override
  Future<TranscriptionResult> transcribe({
    required String audioPath,
    String? initialPrompt,
    void Function(int percent)? onProgress,
  }) async {
    prompt = initialPrompt;
    return TranscriptionResult(
      segments: [TranscriptSegment(startMs: 0, endMs: 1000, text: '台積電')],
      elapsed: Duration.zero,
    );
  }
}

class _FakeRecordingStore implements RecordingStore {
  @override
  Future<String> resolveAudioPath(Recording recording) async => '/audio.wav';

  @override
  Future<void> save(Recording recording) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Recording _recording() => Recording(
  id: '1',
  audioName: 'a.m4a',
  createdAt: DateTime(2026, 10, 21),
  model: 'base',
  elapsedSeconds: 0,
  audioFileName: 'a.m4a',
  segments: [],
);

void main() {
  late Directory dir;
  late GlossaryStore glossary;
  late _FakeTranscription transcription;
  late RecordingTranscriber transcriber;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('transcriber_test');
    glossary = GlossaryStore(documentsDir: () async => dir);
    transcription = _FakeTranscription();
    transcriber = RecordingTranscriber(
      transcription: transcription,
      store: _FakeRecordingStore(),
      glossary: glossary,
    );
  });

  tearDown(() => dir.delete(recursive: true));

  test('passes the glossary to whisper as the initial prompt', () async {
    await glossary.add('台積電');

    await transcriber.transcribe(_recording());

    expect(transcription.prompt, '以下是繁體中文的會議逐字稿，會提到：台積電。');
  });

  test('without a glossary the prompt is just the lead sentence', () async {
    await transcriber.transcribe(_recording());

    expect(transcription.prompt, '以下是繁體中文的會議逐字稿。');
  });

  test('a corrupt glossary does not block transcription', () async {
    await File('${dir.path}/glossary.json').writeAsString('{not json');
    final recording = _recording();

    await transcriber.transcribe(recording);

    expect(transcription.prompt, '以下是繁體中文的會議逐字稿。');
    expect(recording.isTranscribed, isTrue);
  });
}
