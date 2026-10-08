import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/recording.dart';
import '../services/live_transcription_service.dart';
import '../services/mic_stream_service.dart';
import '../services/recording_store.dart';
import '../services/recording_transcriber.dart';
import '../services/transcription_service.dart';
import 'meeting_detail_screen.dart';

/// Records from the mic with a live (draft) transcript, then runs the
/// offline transcription on the saved WAV. State machine: see the spec's
/// "即時錄音的狀態機".
class LiveRecordScreen extends StatefulWidget {
  const LiveRecordScreen({super.key});

  @override
  State<LiveRecordScreen> createState() => _LiveRecordScreenState();
}

enum _Phase {
  checkingPermission,
  permissionDenied,
  preparing,
  recording,
  finalizing,
  transcribing,
  error,
}

class _LiveRecordScreenState extends State<LiveRecordScreen> {
  final _mic = MicStreamService();
  final _service = LiveTranscriptionService();
  final _store = RecordingStore();
  late final _transcriber = RecordingTranscriber(store: _store);
  final _scroll = ScrollController();
  late final AppLifecycleListener _lifecycle;

  _Phase _phase = _Phase.checkingPermission;
  String? _prepareStatus;
  String? _error;

  /// Why recording ended, when it wasn't the stop button.
  String? _endNote;

  LiveRecording? _rec;
  Timer? _ticker;
  String _preview = '';
  bool _previewDelayed = false;
  bool _previewStopped = false;
  bool _nearLimit = false;
  int _transcribeProgress = 0;

  /// Saved (untranscribed) recording waiting for the app to come back to the
  /// foreground before transcribing — transcription runs in the foreground
  /// only.
  Recording? _pendingTranscription;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    _begin();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _ticker?.cancel();
    // Normally impossible (back is intercepted while recording); if the
    // screen goes anyway, stop — _onRecordingDone still saves the audio.
    _rec?.stop();
    _scroll.dispose();
    super.dispose();
  }

  void _setPhase(_Phase phase) {
    if (mounted) setState(() => _phase = phase);
  }

  Future<void> _begin() async {
    setState(() {
      _phase = _Phase.checkingPermission;
      _error = null;
    });
    try {
      var permission = await _mic.permissionStatus();
      if (permission == MicPermission.undetermined) {
        permission = await _mic.requestPermission() ? MicPermission.granted : MicPermission.denied;
      }
      if (permission != MicPermission.granted) {
        _setPhase(_Phase.permissionDenied);
        return;
      }

      _setPhase(_Phase.preparing);
      var lastPercent = -1;
      await _service.ensureModels(
        onProgress: (model, received, total) {
          final percent = total == null ? -1 : received * 100 ~/ total;
          if (percent == lastPercent && total != null) return;
          lastPercent = percent;
          final mb = received ~/ (1024 * 1024);
          if (mounted) {
            setState(
              () => _prepareStatus = total == null
                  ? '下載 ${model.modelName} 模型… ${mb}MB'
                  : '下載 ${model.modelName} 模型… $percent%',
            );
          }
        },
      );
      if (!mounted) return;
      setState(() => _prepareStatus = '載入模型…');

      final id = DateTime.now().millisecondsSinceEpoch.toString();
      final startedAt = DateTime.now();
      final audioFileName = '$id.wav';
      final wavPath = '${(await _store.recordingsDir()).path}/$audioFileName';
      final rec = await _service.start(wavPath: wavPath);
      if (!mounted) {
        // Left while loading; nothing worth keeping yet.
        await rec.stop();
        await _deleteQuietly(wavPath);
        return;
      }
      _rec = rec;
      rec.preview.listen(_onPreview, onError: (_) {});
      rec.notices.listen(_onNotice);
      unawaited(
        rec.done.then((result) => _onRecordingDone(result, id, audioFileName, wavPath, startedAt)),
      );
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      _setPhase(_Phase.recording);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = '無法開始錄音：$e';
      });
    }
  }

  void _onPreview(String text) {
    if (!mounted) return;
    setState(() => _preview = text);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _onNotice(LiveNotice notice) {
    if (!mounted) return;
    setState(() {
      switch (notice) {
        case LiveNotice.previewDelayed:
          _previewDelayed = true;
        case LiveNotice.previewCaughtUp:
          _previewDelayed = false;
        case LiveNotice.previewStopped:
          _previewStopped = true;
        case LiveNotice.nearLimit:
          _nearLimit = true;
      }
    });
  }

  Future<void> _stop() async {
    if (_phase != _Phase.recording) return;
    _setPhase(_Phase.finalizing);
    await _rec?.stop();
  }

  /// Every way recording can end lands here: save first (so the audio is
  /// never lost), then transcribe.
  Future<void> _onRecordingDone(
    LiveRecordingResult result,
    String id,
    String audioFileName,
    String wavPath,
    DateTime startedAt,
  ) async {
    _ticker?.cancel();
    _endNote = switch (result.reason) {
      LiveEndReason.stopped => null,
      LiveEndReason.interrupted => '錄音被來電或其他 App 中斷，已保存到中斷前的內容',
      LiveEndReason.backgrounded => 'App 進入背景，錄音已停止並保存',
      LiveEndReason.writeFailed => '寫入錄音檔失敗（可能是儲存空間不足），已保存寫入成功的部分',
      LiveEndReason.limitReached => '已達 2 小時上限，錄音自動停止',
      LiveEndReason.micError => '麥克風發生錯誤，錄音已停止',
    };
    _setPhase(_Phase.finalizing);

    if (!result.wavUsable || result.audioDuration < const Duration(seconds: 1)) {
      await _deleteQuietly(wavPath);
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = [
          ?_endNote,
          result.wavUsable ? '錄音太短，沒有保存' : '錄音檔無法完成寫入，已刪除殘缺的檔案',
        ].join('\n');
      });
      return;
    }

    final recording = Recording(
      id: id,
      audioName: '即時錄音 ${_formatDateTime(startedAt)}',
      createdAt: startedAt,
      model: kWhisperModel.modelName,
      elapsedSeconds: 0,
      audioFileName: audioFileName,
      segments: [],
      source: RecordingSource.live,
    );
    try {
      await _store.save(recording);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = '保存錄音失敗：$e';
      });
      return;
    }

    if (!mounted) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      _pendingTranscription = recording;
      return;
    }
    await _transcribe(recording);
  }

  void _onResume() {
    final pending = _pendingTranscription;
    if (pending == null || !mounted) return;
    _pendingTranscription = null;
    _transcribe(pending);
  }

  Future<void> _transcribe(Recording recording) async {
    setState(() {
      _phase = _Phase.transcribing;
      _transcribeProgress = 0;
    });
    try {
      await _transcriber.transcribe(
        recording,
        onProgress: (percent) {
          if (mounted) setState(() => _transcribeProgress = percent);
        },
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => MeetingDetailScreen(recording: recording)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = [
          ?_endNote,
          e is NoSpeechDetectedException ? '沒有辨識出任何內容' : '轉錄失敗：$e',
          '錄音已保存，可以之後從詳細頁「重新轉錄」',
        ].join('\n');
      });
    }
  }

  Future<void> _confirmLeave() async {
    final stop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('正在錄音'),
        content: const Text('要停止錄音並保存嗎？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('繼續錄音')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('停止並存檔')),
        ],
      ),
    );
    if (stop == true) await _stop();
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  static String _formatDateTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  /// Maps normalized RMS to the bar on a dB scale: -60 dBFS (room tone)
  /// → empty, 0 dBFS → full. Speech sits around -35 to -15 dBFS, so a linear
  /// scale would barely move. Range is provisional, tuned on device.
  static double _levelToBar(double rms) {
    if (rms <= 0) return 0;
    final db = 20 * math.log(rms) / math.ln10;
    return ((db + 60) / 60).clamp(0.0, 1.0);
  }

  static String _formatElapsed(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
  }

  @override
  Widget build(BuildContext context) {
    final recording = _phase == _Phase.recording;
    return PopScope(
      // Decision #12: confirm before leaving a running recording; don't leave
      // mid-save.
      canPop: !recording && _phase != _Phase.finalizing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && recording) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_title)),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: switch (_phase) {
              _Phase.checkingPermission => const Center(child: CircularProgressIndicator()),
              _Phase.permissionDenied => _buildPermissionDenied(),
              _Phase.preparing => _buildBusy(_prepareStatus ?? '準備中…'),
              _Phase.recording => _buildRecording(),
              _Phase.finalizing => _buildBusy('保存錄音中…'),
              _Phase.transcribing => _buildTranscribing(),
              _Phase.error => _buildError(),
            },
          ),
        ),
      ),
    );
  }

  String get _title => switch (_phase) {
    _Phase.recording => '錄音中',
    _Phase.transcribing => '轉錄中',
    _ => '即時錄音',
  };

  Widget _buildPermissionDenied() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.mic_off, size: 48),
          const SizedBox(height: 16),
          const Text('需要麥克風權限才能錄音。\n請到「設定」開啟 echonote 的麥克風權限後再試一次。', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: _mic.openSettings, child: const Text('前往設定')),
          TextButton(onPressed: _begin, child: const Text('我已開啟，重試')),
        ],
      ),
    );
  }

  Widget _buildBusy(String status) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(status, textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _buildRecording() {
    final elapsed = Duration(milliseconds: ((_rec?.sentSeconds ?? 0) * 1000).round());
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.fiber_manual_record, color: Colors.red),
            const SizedBox(width: 8),
            Text(_formatElapsed(elapsed), style: theme.textTheme.headlineMedium),
          ],
        ),
        const SizedBox(height: 8),
        // Input level (echo_core RMS per 100 ms chunk). Visual is provisional.
        StreamBuilder<double>(
          stream: _rec?.level,
          builder: (context, snapshot) => LinearProgressIndicator(
            value: _levelToBar(snapshot.data ?? 0),
            minHeight: 6,
            semanticsLabel: '輸入音量',
          ),
        ),
        if (_nearLimit) _notice(Icons.timer_outlined, '即將達到 2 小時上限，屆時會自動停止'),
        if (_previewStopped)
          _notice(Icons.info_outline, '即時文字已停止，錄音仍在進行，停止後會產生完整逐字稿')
        else if (_previewDelayed)
          _notice(Icons.hourglass_bottom, '即時文字可能延遲'),
        const SizedBox(height: 12),
        Text('即時預覽（停止後會重新產生正式逐字稿）', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            child: Text(_preview.isEmpty ? '請開始說話…' : _preview),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: _stop, icon: const Icon(Icons.stop), label: const Text('停止')),
      ],
    );
  }

  Widget _buildTranscribing() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_endNote != null) ...[
            Text(_endNote!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
          ],
          CircularProgressIndicator(
            value: _transcribeProgress > 0 ? _transcribeProgress / 100 : null,
          ),
          const SizedBox(height: 16),
          Text(_transcribeProgress > 0 ? '轉錄中… $_transcribeProgress%' : '準備中…'),
          const SizedBox(height: 8),
          const Text('請保持 App 開啟直到轉錄完成', style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.red),
          const SizedBox(height: 16),
          Text(_error ?? '發生錯誤', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('返回')),
        ],
      ),
    );
  }

  Widget _notice(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.orange),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: const TextStyle(color: Colors.orange)),
          ),
        ],
      ),
    );
  }
}
