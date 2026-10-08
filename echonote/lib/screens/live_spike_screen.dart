import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import '../services/live_transcription_service.dart';
import '../services/mic_stream_service.dart';

/// TEMPORARY (spec step 0, T0.5): measures whether live transcription keeps
/// up with real time on device. Reachable only in debug builds; delete in
/// T0.8 together with the home screen entry.
class LiveSpikeScreen extends StatefulWidget {
  const LiveSpikeScreen({super.key});

  @override
  State<LiveSpikeScreen> createState() => _LiveSpikeScreenState();
}

enum _Phase { idle, preparing, recording, finalizing }

class _LiveSpikeScreenState extends State<LiveSpikeScreen> {
  final _mic = MicStreamService();
  final _service = LiveTranscriptionService();
  final _player = AudioPlayer();
  String? _lastWav;
  final _scroll = ScrollController();

  WhisperModel _model = WhisperModel.tiny;
  int _threads = 4;

  /// T0.6 round 2: step 3 s, no temperature fallback, cap tokens per segment.
  /// Off = upstream defaults, for comparison.
  bool _tuned = true;

  /// Live mode has no_context and no prompt, so output drifts into
  /// Simplified Chinese; a Traditional prompt nudges the script.
  bool _zhTwPrompt = true;
  static const _zhTwPromptText = '以下是繁體中文的會議逐字稿。';
  _Phase _phase = _Phase.idle;
  String? _status;
  String? _error;

  LiveRecording? _rec;
  final _clock = Stopwatch();
  Timer? _ticker;
  String _text = '';
  Duration? _lastPartialAt;
  final _intervals = <double>[];
  Duration? _finalizeWait;

  /// T0.6: one entry per native inference run (fork metrics + `lag_sec`).
  final _runs = <Map<String, dynamic>>[];

  double get _audioSeconds => _rec?.sentSeconds ?? 0;

  double? get _medianInterval => _median(_intervals);

  double? _medianRun(String key) => _median([
    for (final r in _runs)
      if (r[key] is num) (r[key] as num).toDouble(),
  ]);

  static double? _median(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    if (_phase == _Phase.recording) _rec?.stop();
    _scroll.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _phase = _Phase.preparing;
      _status = '檢查權限…';
      _error = null;
      _text = '';
      _rec = null;
      _intervals.clear();
      _lastPartialAt = null;
      _finalizeWait = null;
      _runs.clear();
    });
    try {
      _log(
        'start model=${_model.modelName} threads=$_threads tuned=$_tuned '
        'zhTwPrompt=$_zhTwPrompt',
      );
      var permission = await _mic.permissionStatus();
      _log('permission=$permission');
      if (permission == MicPermission.undetermined) {
        permission = await _mic.requestPermission() ? MicPermission.granted : MicPermission.denied;
        _log('permission after request=$permission');
      }
      if (permission != MicPermission.granted) {
        throw Exception('沒有麥克風權限（$permission），請到系統設定開啟');
      }

      // T3.8: both models up front, with progress.
      var lastLogged = -1;
      await _service.ensureModels(
        config: LivePreviewConfig(
          model: _model,
          threads: _threads,
          stepSec: 3,
          noFallback: true,
          maxTokens: 64,
        ),
        onProgress: (model, received, total) {
          final mb = received ~/ (1024 * 1024);
          final pct = total == null ? '' : '（${received * 100 ~/ total}%）';
          if (mb ~/ 10 != lastLogged) {
            lastLogged = mb ~/ 10;
            _log(
              'download ${model.modelName} ${mb}MB${total == null ? '' : '/${total ~/ (1024 * 1024)}MB'}',
            );
          }
          if (mounted) setState(() => _status = '下載 ${model.modelName} 模型 ${mb}MB$pct');
        },
      );
      setState(() => _status = '載入 ${_model.modelName} 模型…');
      final wavPath = '${(await getTemporaryDirectory()).path}/spike.wav';
      // T3.4: the same service the real screen will use (mic → WAV + whisper).
      final rec = await _service.start(
        wavPath: wavPath,
        config: LivePreviewConfig(
          model: _model,
          threads: _threads,
          stepSec: _tuned ? 3.0 : 1.5,
          noFallback: _tuned,
          maxTokens: _tuned ? 64 : 0,
          initialPrompt: _zhTwPrompt ? _zhTwPromptText : null,
        ),
      );
      _log('live recording started, wav=$wavPath');
      _rec = rec;
      _clock
        ..reset()
        ..start();
      rec.metrics.listen(_onMetrics);
      rec.notices.listen((n) => _log('notice ${n.name}'));
      rec.preview.listen(_onPartial, onError: (Object e) => _showError('即時辨識錯誤：$e'));
      unawaited(rec.done.then((r) => _onDone(r, wavPath)));
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      setState(() {
        _phase = _Phase.recording;
        _status = null;
      });
    } catch (e, st) {
      _log('start failed: $e\n$st');
      // Idempotent; makes sure a half-started mic never blocks the next start.
      await _mic.stop();
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _status = null;
        _error = '$e';
      });
    }
  }

  void _onPartial(String text) {
    final now = _clock.elapsed;
    final last = _lastPartialAt;
    final interval = last == null ? null : (now - last).inMilliseconds / 1000;
    if (interval != null) _intervals.add(interval);
    _lastPartialAt = now;
    debugPrint(
      '[spike] partial #${_intervals.length + 1} model=${_model.modelName} '
      't=${_secs(now)} audio=${_audioSeconds.toStringAsFixed(1)}s '
      'interval=${interval?.toStringAsFixed(2) ?? '-'}s chars=${text.length}',
    );
    if (!mounted) return;
    setState(() => _text = text);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _onMetrics(Map<String, dynamic> m) {
    // Audio already sent to whisper minus audio the native side had received
    // when this run started: how far the worker's mailbox is behind.
    final lag = _audioSeconds - (m['fed_sec'] as num).toDouble();
    final run = {...m, 'lag_sec': lag, 'rss_mb': ProcessInfo.currentRss / (1024 * 1024)};
    _runs.add(run);
    String f(String key, [int digits = 0]) => (run[key] as num?)?.toStringAsFixed(digits) ?? '-';
    _log(
      'run #${_runs.length} model=${_model.modelName} threads=${run['threads']} '
      'total=${f('total_ms')}ms enc=${f('encode_ms')}ms dec/tok=${f('decode_ms_per_token', 1)}ms '
      'tokens=${run['tokens']} window=${f('window_sec', 1)}s fed=${f('fed_sec', 1)}s '
      'lag=${f('lag_sec', 1)}s rss=${f('rss_mb')}MB',
    );
    if (mounted) setState(() {});
  }

  Future<void> _stop() async {
    if (_phase != _Phase.recording) return;
    setState(() => _phase = _Phase.finalizing);
    _clock.stop();
    final stoppedAt = DateTime.now();
    await _rec!.stop();
    _finalizeWait = DateTime.now().difference(stoppedAt);
    debugPrint(
      '[spike] stop model=${_model.modelName} audio=${_audioSeconds.toStringAsFixed(1)}s '
      'partials=${_intervals.length + 1} median=${_medianInterval?.toStringAsFixed(2)}s '
      'finalizeWait=${_secs(_finalizeWait!)}',
    );
    String med(String key, [int digits = 0]) => _medianRun(key)?.toStringAsFixed(digits) ?? '-';
    final maxLag = _runs.isEmpty
        ? null
        : _runs.map((r) => r['lag_sec'] as double).reduce((a, b) => a > b ? a : b);
    _log(
      'summary model=${_model.modelName} threads=$_threads tuned=$_tuned '
      'zhTwPrompt=$_zhTwPrompt runs=${_runs.length} '
      'median total=${med('total_ms')}ms enc=${med('encode_ms')}ms '
      'dec/tok=${med('decode_ms_per_token', 1)}ms tokens=${med('tokens')} '
      'maxLag=${maxLag?.toStringAsFixed(1) ?? '-'}s '
      'rss first=${(_runs.firstOrNull?['rss_mb'] as num?)?.toStringAsFixed(0) ?? '-'}MB '
      'last=${(_runs.lastOrNull?['rss_mb'] as num?)?.toStringAsFixed(0) ?? '-'}MB',
    );
    if (mounted) setState(() {});
  }

  void _onDone(LiveRecordingResult r, String wavPath) {
    final file = File(wavPath);
    _log(
      'done reason=${r.reason.name} audio=${_secs(r.audioDuration)} '
      'wavBytes=${file.existsSync() ? file.lengthSync() : -1} error=${r.error}',
    );
    _log('final text: ${r.previewText}');
    _ticker?.cancel();
    _clock.stop();
    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _lastWav = wavPath;
      _text = r.previewText;
      if (r.reason != LiveEndReason.stopped) _error = '錄音結束：${r.reason.name} ${r.error ?? ''}';
    });
  }

  void _log(String message) => debugPrint('[spike] $message');

  void _showError(String message) {
    _log('ERROR $message');
    if (mounted) setState(() => _error = message);
  }

  static String _secs(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

  @override
  Widget build(BuildContext context) {
    final recording = _phase == _Phase.recording;
    final sinceLast = _lastPartialAt == null ? null : _clock.elapsed - _lastPartialAt!;
    final median = _medianInterval;

    return Scaffold(
      appBar: AppBar(title: const Text('即時辨識技術驗證')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<WhisperModel>(
              segments: const [
                ButtonSegment(value: WhisperModel.base, label: Text('base')),
                ButtonSegment(value: WhisperModel.tiny, label: Text('tiny')),
              ],
              selected: {_model},
              onSelectionChanged: _phase == _Phase.idle
                  ? (s) => setState(() => _model = s.single)
                  : null,
            ),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 2, label: Text('2 threads')),
                ButtonSegment(value: 4, label: Text('4 threads')),
              ],
              selected: {_threads},
              onSelectionChanged: _phase == _Phase.idle
                  ? (s) => setState(() => _threads = s.single)
                  : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('調校：3 秒重算、不重解碼、每段最多 64 token'),
              value: _tuned,
              onChanged: _phase == _Phase.idle ? (v) => setState(() => _tuned = v) : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('繁體 prompt：「$_zhTwPromptText」'),
              value: _zhTwPrompt,
              onChanged: _phase == _Phase.idle ? (v) => setState(() => _zhTwPrompt = v) : null,
            ),
            FilledButton.icon(
              onPressed: switch (_phase) {
                _Phase.idle => _start,
                _Phase.recording => _stop,
                _ => null,
              },
              icon: Icon(recording ? Icons.stop : Icons.mic),
              label: Text(switch (_phase) {
                _Phase.idle => '開始',
                _Phase.preparing => '準備中…',
                _Phase.recording => '停止',
                _Phase.finalizing => '定稿中…',
              }),
            ),
            const SizedBox(height: 12),
            if (_status != null) Text(_status!),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            DefaultTextStyle.merge(
              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('錄音時間：${_secs(_clock.elapsed)}'),
                  Text('已送出音訊：${_audioSeconds.toStringAsFixed(1)}s'),
                  Text('partial 次數：${_lastPartialAt == null ? 0 : _intervals.length + 1}'),
                  Text(
                    'partial 間隔：上次 ${_intervals.isEmpty ? '-' : '${_intervals.last.toStringAsFixed(2)}s'}'
                    '／中位數 ${median == null ? '-' : '${median.toStringAsFixed(2)}s'}',
                  ),
                  Text('距上次 partial：${sinceLast == null ? '-' : _secs(sinceLast)}'),
                  if (_finalizeWait != null) Text('停止後等待定稿：${_secs(_finalizeWait!)}'),
                  if (_runs.isNotEmpty) ...[
                    Text(
                      '辨識次數：${_runs.length}／單次耗時 上次 '
                      '${(_runs.last['total_ms'] as num).toStringAsFixed(0)}ms'
                      '／中位數 ${_medianRun('total_ms')!.toStringAsFixed(0)}ms',
                    ),
                    Text(
                      'encode ${(_runs.last['encode_ms'] as num?)?.toStringAsFixed(0) ?? '-'}ms'
                      '／decode 每 token '
                      '${(_runs.last['decode_ms_per_token'] as num?)?.toStringAsFixed(1) ?? '-'}ms'
                      '／tokens ${_runs.last['tokens']}'
                      '／視窗 ${(_runs.last['window_sec'] as num).toStringAsFixed(1)}s',
                    ),
                    Text(
                      '落後：${(_runs.last['lag_sec'] as double).toStringAsFixed(1)}s'
                      '／記憶體 ${(_runs.last['rss_mb'] as num).toStringAsFixed(0)}MB',
                    ),
                  ],
                ],
              ),
            ),
            if (_lastWav != null && _phase == _Phase.idle)
              TextButton.icon(
                // T1.1: listen for clicks / speed changes after a route change.
                onPressed: () async {
                  await _player.setFilePath(_lastWav!);
                  await _player.play();
                },
                icon: const Icon(Icons.play_arrow),
                label: const Text('播放剛錄的 WAV'),
              ),
            const Divider(height: 24),
            Expanded(
              child: SingleChildScrollView(
                controller: _scroll,
                child: Text(_text.isEmpty ? '（尚無文字）' : _text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
