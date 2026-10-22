import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'mic_stream_service.dart';
import 'recording_store.dart';

/// Debug only: names a recording's WAV to replay through live preview
/// instead of the mic, so the same audio can be run again and again
/// (spec fix-live-preview-repetition, T2):
///   flutter run --dart-define=LIVE_REPLAY_WAV=1729500000000.wav
const kLiveReplayWav = String.fromEnvironment('LIVE_REPLAY_WAV');

/// Stands in for [MicStreamService], feeding a recorded WAV in the same
/// 16 kHz mono PCM16 chunks of [MicStreamService.chunkMs], at real-time pace.
/// The stream ends when the file does, just like pressing stop.
class WavReplayMic extends MicStreamService {
  WavReplayMic(
    this.fileName, {
    RecordingStore? store,
    Future<void> Function(Duration)? delay,
  }) : _store = store ?? RecordingStore(),
       _delay = delay ?? Future<void>.delayed;

  final String fileName;
  final RecordingStore _store;

  /// How the replay waits between chunks; tests pass one that doesn't.
  final Future<void> Function(Duration) _delay;

  /// Header written by [WavWriter]: plain 44-byte PCM.
  static const _headerBytes = 44;
  static const chunkBytes = MicStreamService.sampleRate * 2 * MicStreamService.chunkMs ~/ 1000;

  StreamController<Uint8List>? _controller;

  @override
  Future<MicPermission> permissionStatus() async => MicPermission.granted;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<Stream<Uint8List>> start() async {
    if (_controller != null) {
      throw MicStreamException(MicStreamErrorCode.alreadyRunning, 'Replay is already running');
    }
    final file = File('${(await _store.recordingsDir()).path}/$fileName');
    if (!await file.exists()) {
      throw MicStreamException(MicStreamErrorCode.unknown, await _notFoundMessage());
    }
    final bytes = await file.readAsBytes();
    final controller = _controller = StreamController<Uint8List>();
    unawaited(_feed(controller, bytes));
    return controller.stream;
  }

  /// Schedules each chunk against the start time, so slow frames don't add
  /// up to drift.
  Future<void> _feed(StreamController<Uint8List> controller, Uint8List bytes) async {
    final clock = Stopwatch()..start();
    var index = 0;
    for (var offset = _headerBytes; offset < bytes.length; offset += chunkBytes) {
      if (controller.isClosed) return;
      final due = Duration(milliseconds: index * MicStreamService.chunkMs) - clock.elapsed;
      if (due > Duration.zero) await _delay(due);
      if (controller.isClosed) return;
      final end = offset + chunkBytes < bytes.length ? offset + chunkBytes : bytes.length;
      controller.add(Uint8List.sublistView(bytes, offset, end));
      index++;
    }
    await _close();
  }

  @override
  Future<void> stop() => _close();

  Future<void> _close() async {
    final controller = _controller;
    _controller = null;
    if (controller == null || controller.isClosed) return;
    // Not awaited: close() on a never-listened controller never completes.
    unawaited(controller.close());
  }

  /// Lists what can be replayed, since file names aren't shown in the app.
  Future<String> _notFoundMessage() async {
    final recordings = await _store.loadAll();
    final available = [
      for (final r in recordings) '${r.audioFileName}（${r.audioName}）',
    ];
    final message = '找不到要重播的錄音檔 $fileName。可用的檔案：\n${available.join('\n')}';
    debugPrint('[Replay] $message');
    return message;
  }
}
