import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:echonote/services/live_transcription_service.dart';
import 'package:echonote/services/mic_stream_service.dart';
import 'package:echonote/services/wav_writer.dart';
import 'package:flutter_test/flutter_test.dart';

/// A mic whose chunks the test pushes by hand; stop() ends the stream.
class _FakeMic extends MicStreamService {
  final chunks = StreamController<Uint8List>();

  @override
  Future<void> stop() async {
    if (!chunks.isClosed) await chunks.close();
  }
}

class _FakePreview implements PreviewSession {
  _FakePreview(this.pcm);

  final Stream<Uint8List> pcm;
  final received = <Uint8List>[];
  final partialsCtl = StreamController<String>.broadcast();
  final metricsCtl = StreamController<Map<String, dynamic>>.broadcast();
  String finalText = '';
  bool stopped = false;

  void listenToPcm() => pcm.listen(received.add);

  @override
  Stream<String> get partials => partialsCtl.stream;

  @override
  Stream<Map<String, dynamic>> get metrics => metricsCtl.stream;

  @override
  Future<String> stop() async {
    stopped = true;
    await partialsCtl.close();
    await metricsCtl.close();
    return finalText;
  }
}

/// 100 ms of PCM16 at 16 kHz, every sample set to [value].
Uint8List _chunk(int value) {
  final samples = Int16List(1600)..fillRange(0, 1600, value);
  return samples.buffer.asUint8List();
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late Directory dir;
  late _FakeMic mic;
  late WavWriter wav;
  late List<_FakePreview> previews;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('live_recording_test');
    mic = _FakeMic();
    wav = await WavWriter.open('${dir.path}/a.wav');
    previews = [];
  });

  tearDown(() => dir.delete(recursive: true));

  LiveRecording record() => LiveRecording(
    mic: mic,
    micStream: mic.chunks.stream,
    wav: wav,
    openPreview: (pcm) async {
      final preview = _FakePreview(pcm)..listenToPcm();
      previews.add(preview);
      return preview;
    },
  );

  test('without preview: writes the WAV and the level, no preview text', () async {
    final rec = record();
    final levels = <double>[];
    final previewTexts = <String>[];
    rec.level.listen(levels.add);
    rec.preview.listen(previewTexts.add);

    mic.chunks
      ..add(_chunk(1000))
      ..add(_chunk(1000));
    await _settle();
    final result = await rec.stop();

    expect(previews, isEmpty, reason: 'no recognizer is started');
    expect(rec.previewOn, isFalse);
    expect(levels, hasLength(2));
    expect(levels.first, greaterThan(0));
    expect(previewTexts, isEmpty);
    expect(result.previewText, '');
    expect(result.wavUsable, isTrue);
    expect(result.audioDuration, const Duration(milliseconds: 200));
    expect(File('${dir.path}/a.wav').lengthSync(), 44 + 2 * 3200);
  });

  test('preview turned on mid-recording only hears audio from then on', () async {
    final rec = record();
    final previewTexts = <String>[];
    rec.preview.listen(previewTexts.add);

    mic.chunks.add(_chunk(1));
    await _settle();
    await rec.startPreview();
    mic.chunks.add(_chunk(2));
    await _settle();
    previews.single.partialsCtl.add('經常經常經常經常，好');
    await _settle();

    expect(rec.previewOn, isTrue);
    expect(previews.single.received, hasLength(1));
    expect(Int16List.view(previews.single.received.single.buffer).first, 2);
    // Starts empty, then shows the collapsed text.
    expect(previewTexts, ['', '經常，好']);
    await rec.stop();
  });

  test('turning preview off stops updates and the recognizer', () async {
    final rec = record();
    final previewTexts = <String>[];
    rec.preview.listen(previewTexts.add);
    await rec.startPreview();
    final first = previews.single;

    await rec.stopPreview();
    mic.chunks.add(_chunk(3));
    await _settle();

    expect(rec.previewOn, isFalse);
    expect(first.stopped, isTrue);
    expect(first.received, isEmpty);
    final result = await rec.stop();
    expect(result.previewText, '', reason: 'preview was off when recording ended');
  });

  test('turning preview back on starts a fresh session', () async {
    final rec = record();
    await rec.startPreview();
    await rec.stopPreview();
    await rec.startPreview();

    expect(previews, hasLength(2));
    expect(previews.first.stopped, isTrue);
    expect(previews.last.stopped, isFalse);
    await rec.stop();
  });

  test('stopping with preview on returns its final text, collapsed', () async {
    final rec = record();
    await rec.startPreview();
    previews.single.finalText = '好好好好，結束';

    final result = await rec.stop();

    expect(previews.single.stopped, isTrue);
    expect(result.previewText, '好，結束');
  });

  test('a recognizer that fails to start leaves the recording going', () async {
    final rec = LiveRecording(
      mic: mic,
      micStream: mic.chunks.stream,
      wav: wav,
      openPreview: (_) async => throw StateError('no model'),
    );

    await expectLater(rec.startPreview(), throwsStateError);
    expect(rec.previewOn, isFalse);

    mic.chunks.add(_chunk(4));
    await _settle();
    final result = await rec.stop();
    expect(result.audioDuration, const Duration(milliseconds: 100));
  });
}
