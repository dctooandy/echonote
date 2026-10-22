import 'dart:io';
import 'dart:typed_data';

import 'package:echonote/models/recording.dart';
import 'package:echonote/services/mic_stream_service.dart';
import 'package:echonote/services/recording_store.dart';
import 'package:echonote/services/wav_replay_mic.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStore implements RecordingStore {
  _FakeStore(this.dir, [this.recordings = const []]);

  final Directory dir;
  final List<Recording> recordings;

  @override
  Future<Directory> recordingsDir() async => dir;

  @override
  Future<List<Recording>> loadAll() async => recordings;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A 44-byte header (contents don't matter to the replay) plus [pcmBytes]
/// of audio whose byte i is i % 256.
Future<void> _writeWav(File file, int pcmBytes) =>
    file.writeAsBytes([...List.filled(44, 0), for (var i = 0; i < pcmBytes; i++) i % 256]);

void main() {
  late Directory dir;
  late List<Duration> waits;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('replay_test');
    waits = [];
  });

  tearDown(() => dir.delete(recursive: true));

  WavReplayMic replay(String name, [List<Recording> recordings = const []]) => WavReplayMic(
    name,
    store: _FakeStore(dir, recordings),
    delay: (d) async => waits.add(d),
  );

  test('feeds the audio after the header in 100 ms chunks, then ends', () async {
    // 2.5 chunks of audio.
    await _writeWav(File('${dir.path}/a.wav'), WavReplayMic.chunkBytes * 5 ~/ 2);

    final chunks = await (await replay('a.wav').start()).toList();

    expect(WavReplayMic.chunkBytes, 3200);
    expect(chunks.map((c) => c.length), [3200, 3200, 1600]);
    expect(chunks.first.first, 0, reason: 'starts right after the header');
    expect(chunks[1].first, 3200 % 256);
  });

  test('paces chunks 100 ms apart from the start', () async {
    await _writeWav(File('${dir.path}/a.wav'), WavReplayMic.chunkBytes * 4);

    await (await replay('a.wav').start()).toList();

    // The first chunk goes out at once; the rest wait until 100, 200, 300 ms.
    expect(waits, hasLength(3));
    for (final (i, wait) in waits.indexed) {
      final target = Duration(milliseconds: (i + 1) * 100);
      expect(wait, lessThanOrEqualTo(target));
      expect(wait, greaterThan(target - const Duration(milliseconds: 50)));
    }
  });

  test('stop ends the stream early', () async {
    await _writeWav(File('${dir.path}/a.wav'), WavReplayMic.chunkBytes * 50);
    final mic = WavReplayMic(
      'a.wav',
      store: _FakeStore(dir),
      delay: (d) => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    final stream = await mic.start();
    final received = <Uint8List>[];

    final done = stream.forEach(received.add);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await mic.stop();
    await done;

    expect(received.length, lessThan(50));
  });

  test('a missing file fails with the recordings that can be replayed', () async {
    final recording = Recording(
      id: '1',
      audioName: '即時錄音 2026/10/21 15:30',
      createdAt: DateTime(2026, 10, 21),
      model: 'base',
      elapsedSeconds: 0,
      audioFileName: '1.wav',
      segments: [],
    );

    await expectLater(
      replay('missing.wav', [recording]).start(),
      throwsA(
        isA<MicStreamException>().having(
          (e) => e.message,
          'message',
          allOf(contains('missing.wav'), contains('1.wav（即時錄音 2026/10/21 15:30）')),
        ),
      ),
    );
  });

  test('stands in for the mic without asking for permission', () async {
    final mic = replay('a.wav');

    expect(await mic.permissionStatus(), MicPermission.granted);
    expect(await mic.requestPermission(), isTrue);
  });
}
