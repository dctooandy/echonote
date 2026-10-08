import '../models/recording.dart';
import 'recording_store.dart';
import 'transcription_service.dart';

class NoSpeechDetectedException implements Exception {
  const NoSpeechDetectedException();

  @override
  String toString() => '沒有辨識出任何內容，請確認錄音檔案是否正常';
}

/// Offline transcription for a [Recording] whose audio is already in the
/// recordings directory. Shared by import, live recording (after stop) and
/// "re-transcribe".
class RecordingTranscriber {
  RecordingTranscriber({TranscriptionService? transcription, RecordingStore? store})
    : _transcription = transcription ?? TranscriptionService(),
      _store = store ?? RecordingStore();

  final TranscriptionService _transcription;
  final RecordingStore _store;

  /// On success fills in [recording]'s segments and elapsed time and saves
  /// it. Throws [NoSpeechDetectedException] when nothing was recognized, or
  /// the transcription error; in both cases [recording] is left untouched
  /// (still untranscribed) and nothing is written.
  Future<void> transcribe(Recording recording, {void Function(int percent)? onProgress}) async {
    final result = await _transcription.transcribe(
      audioPath: await _store.resolveAudioPath(recording),
      onProgress: onProgress,
    );
    if (result.segments.isEmpty) throw const NoSpeechDetectedException();

    recording
      ..segments = result.segments
      ..elapsedSeconds = result.elapsed.inSeconds;
    await _store.save(recording);
  }
}
