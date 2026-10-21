import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import '../models/recording.dart';

/// v1 always uses the `base` model — see project decision: `small` costs ~80%
/// more time and 3.3x the storage for no measurable accuracy gain on messy
/// real-world recordings.
const kWhisperModel = WhisperModel.base;

/// Keep the prompt in every window. Override to compare on device (spec
/// task T4): `flutter run --dart-define=WHISPER_CARRY_PROMPT=false`
const kCarryInitialPrompt = bool.fromEnvironment('WHISPER_CARRY_PROMPT', defaultValue: true);

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

  /// [initialPrompt] biases decoding toward the glossary's spelling; see
  /// `buildWhisperPrompt`. It is carried into every 30 s window, since by
  /// default whisper only seeds the first one and the decoded text soon pushes
  /// it out of the context.
  Future<TranscriptionResult> transcribe({
    required String audioPath,
    String? initialPrompt,
    void Function(int percent)? onProgress,
  }) async {
    final safeAudioPath = await _sanitizedAudioPath(audioPath);
    await _controller.downloadModel(kWhisperModel);

    final stopwatch = Stopwatch()..start();
    final result = await _controller.transcribe(
      model: kWhisperModel,
      audioPath: safeAudioPath,
      lang: 'zh',
      initialPrompt: initialPrompt,
      carryInitialPrompt: kCarryInitialPrompt,
      withSegments: true,
      // Some recordings (e.g. 261009_與老師討論AHP.mp3) make whisper open
      // every 30 s window with a non-speech tag like "(咖啡)" and skip the
      // rest of the window, so the whole transcript is that one tag.
      // Suppressing those tags restores the real speech.
      suppressNonSpeechTokens: true,
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
