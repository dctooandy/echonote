import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:echo_core/echo_core.dart' as echo;
import 'package:flutter/foundation.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import 'mic_stream_service.dart';
import 'repetition.dart';
import 'transcription_service.dart';
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
    this.audioCtx = 0,
    this.commitSec = 25,
    this.initialPrompt,
  });

  final WhisperModel model;
  final int threads;
  final double stepSec;
  final bool noFallback;
  final int maxTokens;

  /// Encoder context: 0 = whisper's default (30 s), -1 = sized to each
  /// run's window, >0 = fixed frames (50 per second; must cover
  /// [commitSec]).
  final int audioCtx;

  /// Seconds the preview window grows before its text is committed.
  final int commitSec;
  final String? initialPrompt;
}

/// `tiny` keeps up where `base` doesn't; the final transcript still comes
/// from the offline `base` pass. Live mode decodes with no_context, so
/// without a prompt it drifts into Simplified Chinese; this prompt fixed
/// that on device (2026-10-08).
const kLivePreviewConfig = LivePreviewConfig(
  model: WhisperModel.tiny,
  threads: 4,
  stepSec: 3,
  noFallback: true,
  maxTokens: 64,
  initialPrompt: '以下是繁體中文的會議逐字稿。',
  // A fixed 768-frame encoder context (~15 s) with 15 s commits: median run
  // 1809 → 516 ms and max lag 4.8 → 1.0 s on an iPhone 12 Pro Max, text no
  // worse (2026-10-10). Sizing audio_ctx per run (-1) was fast but fell into
  // repetition loops. Override per build to re-measure:
  //   flutter run --dart-define=LIVE_AUDIO_CTX=0 --dart-define=LIVE_COMMIT_SEC=25
  audioCtx: int.fromEnvironment('LIVE_AUDIO_CTX', defaultValue: 768),
  commitSec: int.fromEnvironment('LIVE_COMMIT_SEC', defaultValue: 15),
);

/// Collapse repetition loops in the preview, natively before each commit
/// and here before display. Off only to compare on the same audio (spec
/// fix-live-preview-repetition):
///   flutter run --dart-define=LIVE_COLLAPSE=false
const kLiveCollapse = bool.fromEnvironment('LIVE_COLLAPSE', defaultValue: true);

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
    required this.wavUsable,
    this.error,
  });

  final LiveEndReason reason;

  /// Last live-preview text. Only a draft — the saved transcript comes from
  /// the offline pass over the WAV.
  final String previewText;

  /// Audio that actually reached the WAV file.
  final Duration audioDuration;

  /// False when the WAV header couldn't be finalized (e.g. disk full while
  /// patching it): the file is broken and should be deleted, not saved.
  final bool wavUsable;

  /// The mic or write error behind [reason], if any.
  final Object? error;
}

class LiveTranscriptionService {
  LiveTranscriptionService({MicStreamService? mic, WhisperController? whisper})
    : _mic = mic ?? MicStreamService(),
      _whisper = whisper ?? WhisperController();

  final MicStreamService _mic;
  final WhisperController _whisper;

  /// Makes sure the offline model used after stop ([kWhisperModel]) is on
  /// disk, downloading it on first use (~147 MB). The live preview's model
  /// is only fetched when live text is first turned on
  /// ([ensurePreviewModel]), so people who never use it don't download it.
  /// Reports which model is in flight and its bytes (`total` null when
  /// unknown).
  Future<void> ensureModels({
    void Function(WhisperModel model, int received, int? total)? onProgress,
  }) => _download(kWhisperModel, onProgress);

  /// Makes sure the live preview's model (~75 MB) is on disk.
  Future<void> ensurePreviewModel({
    LivePreviewConfig config = kLivePreviewConfig,
    void Function(WhisperModel model, int received, int? total)? onProgress,
  }) => _download(config.model, onProgress);

  Future<void> _download(
    WhisperModel model,
    void Function(WhisperModel model, int received, int? total)? onProgress,
  ) => _whisper.downloadModel(
    model,
    onProgress: onProgress == null ? null : (received, total) => onProgress(model, received, total),
  );

  /// Starts the mic, writing audio to [wavPath] as it arrives, and with
  /// [livePreview] the live preview too (see [LiveRecording.startPreview]).
  /// On failure nothing is left running and the WAV file is removed.
  Future<LiveRecording> start({
    required String wavPath,
    required bool livePreview,
    LivePreviewConfig config = kLivePreviewConfig,
  }) async {
    final wav = await WavWriter.open(wavPath, sampleRate: MicStreamService.sampleRate);
    final Stream<Uint8List> micStream;
    try {
      micStream = await _mic.start();
    } catch (_) {
      await _discard(wav, wavPath);
      rethrow;
    }
    final rec = LiveRecording(
      mic: _mic,
      micStream: micStream,
      wav: wav,
      openPreview: (pcm) => _openPreview(pcm, config),
    );
    if (livePreview) {
      try {
        await rec.startPreview();
      } catch (_) {
        await rec.stop();
        try {
          await File(wavPath).delete();
        } catch (_) {}
        rethrow;
      }
    }
    return rec;
  }

  Future<PreviewSession> _openPreview(Stream<Uint8List> pcm, LivePreviewConfig config) async {
    await _whisper.downloadModel(config.model);
    final session = await _whisper.transcribeLive(
      model: config.model,
      pcm16Stream: pcm,
      // Must be explicit: the package defaults to 'en'.
      lang: 'zh',
      initialPrompt: config.initialPrompt,
      threads: config.threads,
      stepSec: config.stepSec,
      noFallback: config.noFallback,
      maxTokens: config.maxTokens,
      audioCtx: config.audioCtx,
      commitSec: config.commitSec.toDouble(),
      collapseRepetitions: kLiveCollapse,
    );
    return _WhisperPreview(session);
  }

  static Future<void> _discard(WavWriter wav, String wavPath) async {
    try {
      await wav.close();
      await File(wavPath).delete();
    } catch (_) {}
  }
}

/// What [LiveRecording] needs from a running recognizer. A seam, so a
/// recording can be tested without the native one.
abstract interface class PreviewSession {
  /// Full text so far, replaced on every update.
  Stream<String> get partials;

  /// Per-run diagnostics from the native side.
  Stream<Map<String, dynamic>> get metrics;

  /// Ends the session; completes with its final text.
  Future<String> stop();
}

/// Starts a recognizer reading [pcm]: PCM16 chunks from the moment it's
/// called.
typedef PreviewOpener = Future<PreviewSession> Function(Stream<Uint8List> pcm);

class _WhisperPreview implements PreviewSession {
  _WhisperPreview(this._session);

  final WhisperLiveSession _session;

  @override
  Stream<String> get partials => _session.partials;

  @override
  Stream<Map<String, dynamic>> get metrics => _session.metrics;

  @override
  Future<String> stop() => _session.stop();
}

/// A running live recording. Ends via [stop], or by itself on an
/// interruption, backgrounding or a write failure — [done] completes either
/// way. Live preview is optional and can be turned on and off while
/// recording ([startPreview], [stopPreview]); without it only the WAV and
/// the input level are produced.
class LiveRecording {
  LiveRecording({
    required this._mic,
    required Stream<Uint8List> micStream,
    required this._wav,
    required this._openPreview,
  }) {
    micStream.listen(_onChunk, onError: _onMicError, onDone: _finish);
  }

  final MicStreamService _mic;
  final WavWriter _wav;
  final PreviewOpener _openPreview;

  /// Set while preview is on: chunks go here as well as to the WAV.
  StreamController<Uint8List>? _previewPcm;
  PreviewSession? _session;
  final List<StreamSubscription<Object?>> _sessionSubs = [];
  bool _previewOn = false;
  bool _finished = false;

  /// Where in the recording the current preview session started.
  double _previewStartSeconds = 0;

  /// Decision #14: recordings stop at 2 hours, with a warning 5 minutes
  /// before.
  static const maxDuration = Duration(hours: 2);
  static const limitWarningBefore = Duration(minutes: 5);

  /// Decision #10: normal lag measured 0.7–2 s; 6 s is about two re-decode
  /// cycles, so occasional slow runs don't trigger it.
  static const lagHintSeconds = 6.0;

  final _preview = StreamController<String>.broadcast();
  final _lag = StreamController<double>.broadcast();
  final _level = StreamController<double>.broadcast();
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

  /// Whether live preview is running.
  bool get previewOn => _previewOn;

  /// Audio written to the WAV (and, with preview on, handed to the
  /// recognizer) so far.
  double get sentSeconds => _sentBytes / (MicStreamService.sampleRate * 2);

  Stream<LiveNotice> get notices => _notices.stream;

  /// Input level (normalized RMS, 0..1) of each 100 ms chunk, computed by
  /// echo_core in C.
  Stream<double> get level => _level.stream;

  Future<LiveRecordingResult> get done => _done.future;

  Future<LiveRecordingResult> stop() async {
    await _mic.stop();
    return done;
  }

  /// Starts live preview from this moment: only audio from now on is
  /// recognized, and the preview starts empty (it isn't joined to text from
  /// an earlier run). Throws if the recognizer fails to start; the recording
  /// carries on either way.
  Future<void> startPreview() async {
    if (_previewOn || _finished) return;
    _previewOn = true;
    // Chunks arriving while the recognizer loads are buffered here; the
    // recognizer's clock starts at this point in the recording.
    final pcm = _previewPcm = StreamController<Uint8List>();
    _previewStartSeconds = sentSeconds;
    final PreviewSession session;
    try {
      session = await _openPreview(pcm.stream);
    } catch (_) {
      _previewOn = false;
      if (identical(_previewPcm, pcm)) _previewPcm = null;
      unawaited(pcm.close());
      rethrow;
    }
    // Turned off, or the recording ended, while it was starting.
    if (!identical(_previewPcm, pcm) || _finished) {
      unawaited(session.stop().catchError((Object _) => ''));
      return;
    }
    _session = session;
    _lastText = '';
    _preview.add('');
    _sessionSubs
      ..add(
        session.partials.listen(
          (text) {
            _lastText = text;
            // Partials are the whole text so far, so collapsing each one is
            // enough; nothing accumulates on this side.
            _preview.add(_collapse(text));
          },
          // A native error ends the preview only; recording continues.
          onError: (Object e, StackTrace st) {
            _preview.addError(e, st);
            _notices.add(LiveNotice.previewStopped);
          },
        ),
      )
      ..add(
        session.metrics.listen((m) {
          _loopsCollapsedNatively += (m['loops_collapsed'] as num?)?.toInt() ?? 0;
          // The final report carries only the loop count, not a run's timings.
          if (!m.containsKey('total_ms')) return;
          if (kDebugMode) _runs.add(m);
          final fedSec = (m['fed_sec'] as num?)?.toDouble();
          // fed_sec counts from when this session started.
          if (fedSec != null) _onLag(sentSeconds - _previewStartSeconds - fedSec);
        }),
      );
  }

  /// Stops live preview. The text already shown stays where the caller put
  /// it; no further updates arrive.
  Future<void> stopPreview() async {
    if (!_previewOn) return;
    _previewOn = false;
    final pcm = _previewPcm;
    final session = _session;
    _previewPcm = null;
    _session = null;
    await _cancelSessionSubs();
    if (_previewDelayed) {
      _previewDelayed = false;
      _notices.add(LiveNotice.previewCaughtUp);
    }
    unawaited(pcm?.close());
    await session?.stop().catchError((Object _) => '');
  }

  Future<void> _cancelSessionSubs() async {
    final subs = [..._sessionSubs];
    _sessionSubs.clear();
    for (final sub in subs) {
      await sub.cancel();
    }
  }

  void _onChunk(Uint8List chunk) {
    _sentBytes += chunk.length;
    _previewPcm?.add(chunk);
    _level.add(echo.rms(_asSamples(chunk)));
    _checkLimit();
    _wav.add(chunk).catchError((Object e) {
      if (_error != null) return;
      _error = e;
      _reason ??= LiveEndReason.writeFailed;
      _mic.stop();
    });
  }

  /// Views [chunk] as PCM16 without copying when it is 2-byte aligned (the
  /// normal case for channel data); copies otherwise. A trailing odd byte is
  /// left out — fine for a level reading.
  static Int16List _asSamples(Uint8List chunk) {
    final bytes = chunk.offsetInBytes.isEven ? chunk : Uint8List.fromList(chunk);
    return Int16List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);
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
    if (kDebugMode && lag > _maxLag) _maxLag = lag;
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

  // Debug builds only: per-run metrics, summarized when the recording ends
  // so preview settings (audio_ctx etc.) can be compared on a device.
  final List<Map<String, dynamic>> _runs = [];
  double _maxLag = 0;
  int _loopsCollapsedNatively = 0;

  String _collapse(String text) => kLiveCollapse ? collapseRepetitions(text).text : text;

  /// Loops the native side removed (at commits and in the final text), and
  /// those still in [rawPreview] — with collapsing off, the loops the
  /// preview would otherwise have hidden.
  void _logRuns(String rawPreview) {
    if (_runs.isEmpty) return;
    final collapsed = collapseRepetitions(rawPreview);

    double median(String key) {
      final v = [for (final m in _runs) (m[key] as num?)?.toDouble() ?? 0]..sort();
      return v[v.length ~/ 2];
    }

    final ctx = {for (final m in _runs) m['audio_ctx']};
    debugPrint(
      '[live-metrics] runs ${_runs.length}, audio_ctx $ctx, '
      'commit_sec ${_runs.first['commit_sec']}, '
      'median total_ms ${median('total_ms').round()}, '
      'median encode_ms ${median('encode_ms').round()}, '
      'median window_sec ${median('window_sec').toStringAsFixed(1)}, '
      'max lag ${_maxLag.toStringAsFixed(1)} s, '
      'collapse ${kLiveCollapse ? 'on' : 'off'}, '
      'loops collapsed natively $_loopsCollapsedNatively, '
      'loops left in preview ${collapsed.collapsed}',
    );
    debugPrint('[live-metrics] preview: ${_collapse(rawPreview)}');
  }

  /// The mic stream ended (stop, system, or write failure): drain both
  /// consumers, then report.
  Future<void> _finish() async {
    _finished = true;
    final pcm = _previewPcm;
    final session = _session;
    _previewPcm = null;
    _session = null;
    _previewOn = false;
    unawaited(pcm?.close());
    // Without preview running at the end there is no final preview text.
    final rawPreview = session == null
        ? ''
        : await session.stop().catchError((Object _) => _lastText);
    await _cancelSessionSubs();
    if (kDebugMode) _logRuns(rawPreview);
    final previewText = _collapse(rawPreview);
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
        wavUsable: _wav.headerFinalized,
        error: _error,
      ),
    );
    await _preview.close();
    await _lag.close();
    await _level.close();
    await _notices.close();
  }
}
