import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import '../models/recording.dart';

/// v1 always uses the `base` model — see project decision: `small` costs ~80%
/// more time and 3.3x the storage for no measurable accuracy gain on messy
/// real-world recordings.
const kWhisperModel = WhisperModel.base;

class TranscriptionResult {
  TranscriptionResult({required this.segments, required this.elapsed});

  final List<TranscriptSegment> segments;
  final Duration elapsed;
}

class TranscriptionService {
  final _controller = WhisperController();

  /// Copies [originalPath] to a temp path with an ASCII, space-free filename.
  ///
  /// Works around a bug in whisper_ggml's bundled ffmpeg invocation: it
  /// doesn't quote the input path, so filenames containing spaces (e.g.
  /// "新錄音 64.m4a") get truncated at the space and the conversion fails.
  Future<String> _sanitizedAudioPath(String originalPath) async {
    final ext = originalPath.split('.').last;
    final tempDir = await getTemporaryDirectory();
    final sanitizedPath = '${tempDir.path}/echonote_input.$ext';
    await File(originalPath).copy(sanitizedPath);
    return sanitizedPath;
  }

  Future<TranscriptionResult> transcribe({
    required String audioPath,
    void Function(int percent)? onProgress,
  }) async {
    final safeAudioPath = await _sanitizedAudioPath(audioPath);
    await _controller.downloadModel(kWhisperModel);

    final stopwatch = Stopwatch()..start();
    final result = await _controller.transcribe(
      model: kWhisperModel,
      audioPath: safeAudioPath,
      lang: 'zh',
      withSegments: true,
      onProgress: onProgress,
    );
    stopwatch.stop();

    final segments = (result?.transcription.segments ?? [])
        .map((s) => TranscriptSegment(
              startMs: s.fromTs.inMilliseconds,
              endMs: s.toTs.inMilliseconds,
              text: s.text.trim(),
            ))
        .toList();

    return TranscriptionResult(segments: segments, elapsed: stopwatch.elapsed);
  }
}
