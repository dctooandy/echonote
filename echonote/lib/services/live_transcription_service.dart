import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:whisper_ggml/whisper_ggml.dart';

import 'mic_stream_service.dart';
import 'wav_writer.dart';

/// Live-preview decoding settings. See the spec's step-0 results: upstream
/// defaults fall behind real time on an iPhone 12 Pro Max within a minute.
class LivePreviewConfig {
  const LivePreviewConfig({
    required this.model,
    required this.threads,
    required this.stepSec,
    required this.noFallback,
    required this.maxTokens,
    this.initialPrompt,
  });

  final WhisperModel model;
  final int threads;
  final double stepSec;
  final bool noFallback;
  final int maxTokens;
  final String? initialPrompt;
}

/// `tiny` keeps up where `base` doesn't; the final transcript still comes
/// from the offline `base` pass. The default prompt is pending the
/// Traditional-Chinese test (live mode drifts into Simplified without one).
const kLivePreviewConfig = LivePreviewConfig(
  model: WhisperModel.tiny,
  threads: 4,
  stepSec: 3,
  noFallback: true,
  maxTokens: 64,
);

enum LiveEndReason {
  /// [LiveRecording.stop] was called.
  stopped,
  interrupted,
  backgrounded,

  /// Writing the WAV failed (e.g. disk full); recording stopped there.
  writeFailed,
  micError,

  /// Hit [LiveRecording.maxDuration].
  limitReached,
}

/// Things the recording screen should tell the user about.
enum LiveNotice {
  /// The preview is more than [LiveRecording.lagHintSeconds] behind. Audio is
  /// never dropped; only the preview lags.
  previewDelayed,

  /// Back within [LiveRecording.lagHintSeconds] after [previewDelayed].
  previewCaughtUp,

  /// The preview hit a native error and stopped; recording continues.
  previewStopped,

  /// [LiveRecording.limitWarningBefore] left until [LiveRecording.maxDuration].
  nearLimit,
}

class LiveRecordingResult {
  LiveRecordingResult({
    required this.reason,
    required this.previewText,
    required this.audioDuration,
    this.error,
  });

  final LiveEndReason reason;

  /// Last live-preview text. Only a draft — the saved transcript comes from
  /// the offline pass over the WAV.
  final String previewText;

  /// Audio that actually reached the WAV file.
  final Duration audioDuration;

  /// The mic or write error behind [reason], if any.
  final Object? error;
}

class LiveTranscriptionService {
  LiveTranscriptionService({MicStreamService? mic, WhisperController? whisper})
    : _mic = mic ?? MicStreamService(),
      _whisper = whisper ?? WhisperController();

  final MicStreamService _mic;
  final WhisperController _whisper;

  /// Downloads (first use only) and loads the preview model, then starts the
  /// mic. Audio is written to [wavPath] as it arrives. On failure nothing is
  /// left running and the WAV file is removed.
  Future<LiveRecording> start({
    required String wavPath,
    LivePreviewConfig config = kLivePreviewConfig,
  }) async {
    await _whisper.downloadModel(config.model);
    final wav = await WavWriter.open(wavPath, sampleRate: MicStreamService.sampleRate);

    // Fed by hand from the single mic subscription, alongside the WAV writer
    // (a single-subscription stream can't be listened to twice).
    final pcm = StreamController<Uint8List>();
    WhisperLiveSession? session;
    try {
      session = await _whisper.transcribeLive(
        model: config.model,
        pcm16Stream: pcm.stream,
        // Must be explicit: the package defaults to 'en'.
        lang: 'zh',
        initialPrompt: config.initialPrompt,
        threads: config.threads,
        stepSec: config.stepSec,
        noFallback: config.noFallback,
        maxTokens: config.maxTokens,
      );
      final micStream = await _mic.start();
      return LiveRecording._(_mic, micStream, pcm, session, wav);
    } catch (_) {
      // Closing the input ends the session, if it started.
      unawaited(pcm.close());
      await session?.stop();
      try {
        await wav.close();
        await File(wavPath).delete();
      } catch (_) {}
      rethrow;
    }
  }
}

/// A running live recording. Ends via [stop], or by itself on an
/// interruption, backgrounding or a write failure — [done] completes either
/// way.
class LiveRecording {
  LiveRecording._(this._mic, Stream<Uint8List> micStream, this._pcm, this._session, this._wav) {
    _session.partials.listen(
      (text) {
        _lastText = text;
        _preview.add(text);
      },
      // A native error ends the preview only; recording continues.
      onError: (Object e, StackTrace st) {
        _preview.addError(e, st);
        _notices.add(LiveNotice.previewStopped);
      },
    );
    _session.metrics.listen((m) {
      final fedSec = (m['fed_sec'] as num?)?.toDouble();
      if (fedSec != null) _onLag(sentSeconds - fedSec);
    });
    micStream.listen(_onChunk, onError: _onMicError, onDone: _finish);
  }

  final MicStreamService _mic;
  final StreamController<Uint8List> _pcm;
  final WhisperLiveSession _session;
  final WavWriter _wav;

  /// Decision #14: recordings stop at 2 hours, with a warning 5 minutes
  /// before.
  static const maxDuration = Duration(hours: 2);
  static const limitWarningBefore = Duration(minutes: 5);

  /// Decision #10: normal lag measured 0.7–2 s; 6 s is about two re-decode
  /// cycles, so occasional slow runs don't trigger it.
  static const lagHintSeconds = 6.0;

  final _preview = StreamController<String>.broadcast();
  final _lag = StreamController<double>.broadcast();
  final _notices = StreamController<LiveNotice>.broadcast();
  bool _previewDelayed = false;
  bool _warnedNearLimit = false;
  final _done = Completer<LiveRecordingResult>();
  String _lastText = '';
  int _sentBytes = 0;
  LiveEndReason? _reason;
  Object? _error;

  /// Full preview text, replaced on every update (not a delta). Errors here
  /// mean the preview stopped; the recording itself goes on.
  Stream<String> get preview => _preview.stream;

  /// Seconds of audio the recognizer is behind, one value per decode run.
  Stream<double> get lagSeconds => _lag.stream;

  /// Raw per-decode-run numbers from the native side (diagnostics).
  Stream<Map<String, dynamic>> get metrics => _session.metrics;

  /// Audio handed to the recognizer and WAV writer so far.
  double get sentSeconds => _sentBytes / (MicStreamService.sampleRate * 2);

  Stream<LiveNotice> get notices => _notices.stream;

  Future<LiveRecordingResult> get done => _done.future;

  Future<LiveRecordingResult> stop() async {
    await _mic.stop();
    return done;
  }

  void _onChunk(Uint8List chunk) {
    _sentBytes += chunk.length;
    _pcm.add(chunk);
    _checkLimit();
    _wav.add(chunk).catchError((Object e) {
      if (_error != null) return;
      _error = e;
      _reason ??= LiveEndReason.writeFailed;
      _mic.stop();
    });
  }

  void _checkLimit() {
    final sent = Duration(microseconds: (sentSeconds * Duration.microsecondsPerSecond).round());
    if (!_warnedNearLimit && sent >= maxDuration - limitWarningBefore) {
      _warnedNearLimit = true;
      _notices.add(LiveNotice.nearLimit);
    }
    if (sent >= maxDuration && _reason == null) {
      _reason = LiveEndReason.limitReached;
      _mic.stop();
    }
  }

  void _onLag(double lag) {
    _lag.add(lag);
    final delayed = lag > lagHintSeconds;
    if (delayed == _previewDelayed) return;
    _previewDelayed = delayed;
    _notices.add(delayed ? LiveNotice.previewDelayed : LiveNotice.previewCaughtUp);
  }

  void _onMicError(Object e) {
    _error ??= e;
    _reason ??= switch (e) {
      MicStreamException(code: MicStreamErrorCode.interrupted) => LiveEndReason.interrupted,
      MicStreamException(code: MicStreamErrorCode.backgrounded) => LiveEndReason.backgrounded,
      _ => LiveEndReason.micError,
    };
  }

  /// The mic stream ended (stop, system, or write failure): drain both
  /// consumers, then report.
  Future<void> _finish() async {
    unawaited(_pcm.close());
    final previewText = await _session.stop().catchError((Object _) => _lastText);
    try {
      await _wav.close();
    } catch (e) {
      _error ??= e;
      _reason ??= LiveEndReason.writeFailed;
    }
    _done.complete(
      LiveRecordingResult(
        reason: _reason ?? LiveEndReason.stopped,
        previewText: previewText,
        audioDuration: _wav.duration,
        error: _error,
      ),
    );
    await _preview.close();
    await _lag.close();
    await _notices.close();
  }
}
