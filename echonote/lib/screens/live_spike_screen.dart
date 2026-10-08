import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

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
  final _whisper = WhisperController();
  final _scroll = ScrollController();

  WhisperModel _model = WhisperModel.base;
  _Phase _phase = _Phase.idle;
  String? _status;
  String? _error;

  WhisperLiveSession? _session;
  final _clock = Stopwatch();
  Timer? _ticker;
  int _audioBytes = 0;
  String _text = '';
  Duration? _lastPartialAt;
  final _intervals = <double>[];
  Duration? _finalizeWait;

  double get _audioSeconds => _audioBytes / (MicStreamService.sampleRate * 2);

  double? get _medianInterval {
    if (_intervals.isEmpty) return null;
    final sorted = [..._intervals]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    if (_phase == _Phase.recording) _mic.stop();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _phase = _Phase.preparing;
      _status = '檢查權限…';
      _error = null;
      _text = '';
      _audioBytes = 0;
      _intervals.clear();
      _lastPartialAt = null;
      _finalizeWait = null;
    });
    try {
      _log('start model=${_model.modelName}');
      var permission = await _mic.permissionStatus();
      _log('permission=$permission');
      if (permission == MicPermission.undetermined) {
        permission = await _mic.requestPermission() ? MicPermission.granted : MicPermission.denied;
        _log('permission after request=$permission');
      }
      if (permission != MicPermission.granted) {
        throw Exception('沒有麥克風權限（$permission），請到系統設定開啟');
      }

      setState(() => _status = '下載／確認 ${_model.modelName} 模型…');
      final modelPath = await _whisper.downloadModel(_model);
      _log('model ready: $modelPath');

      setState(() => _status = '載入模型…');
      final pcm = await _mic.start();
      _log('mic started');
      // Count bytes as whisper consumes them; surface mic errors
      // (interrupted / backgrounded) before transcribeLive swallows them.
      final counted = pcm.transform(
        StreamTransformer<Uint8List, Uint8List>.fromHandlers(
          handleData: (chunk, sink) {
            if (_audioBytes == 0) _log('first mic chunk: ${chunk.length} bytes');
            _audioBytes += chunk.length;
            sink.add(chunk);
          },
          handleError: (e, st, sink) {
            _showError('麥克風串流錯誤：$e');
            sink.addError(e, st);
          },
          handleDone: (sink) {
            _log('mic stream done, audio=${_audioSeconds.toStringAsFixed(1)}s');
            sink.close();
          },
        ),
      );

      final WhisperLiveSession session;
      try {
        session = await _whisper.transcribeLive(model: _model, pcm16Stream: counted, lang: 'zh');
      } catch (e) {
        _log('transcribeLive failed: $e');
        await _mic.stop();
        rethrow;
      }
      _log('live session started');
      _session = session;
      _clock
        ..reset()
        ..start();
      // `partials` closes once the session has finalized — by our stop, a
      // system stop (interruption, backgrounding) or a native error. Don't
      // use session.stop() to wait for that: calling it *ends* the session.
      session.partials.listen(
        _onPartial,
        onError: (Object e) => _showError('即時辨識錯誤：$e'),
        onDone: () async => _onSessionDone(await session.stop()),
      );
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

  Future<void> _stop() async {
    if (_phase != _Phase.recording) return;
    setState(() => _phase = _Phase.finalizing);
    _clock.stop();
    final stoppedAt = DateTime.now();
    await _mic.stop();
    await _session!.stop();
    _finalizeWait = DateTime.now().difference(stoppedAt);
    debugPrint(
      '[spike] stop model=${_model.modelName} audio=${_audioSeconds.toStringAsFixed(1)}s '
      'partials=${_intervals.length + 1} median=${_medianInterval?.toStringAsFixed(2)}s '
      'finalizeWait=${_secs(_finalizeWait!)}',
    );
    if (mounted) setState(() {});
  }

  void _onSessionDone(String finalText) {
    _log('session done, final chars=${finalText.length}');
    // The session can end on its own (native whisper error, mic error); the
    // mic would otherwise keep running and block the next start.
    _mic.stop();
    _ticker?.cancel();
    _clock.stop();
    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _text = finalText;
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
            const SizedBox(height: 12),
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
                ],
              ),
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
