import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

void main() {
  runApp(const EchoNoteApp());
}

class EchoNoteApp extends StatelessWidget {
  const EchoNoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'echonote Whisper POC',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: const TranscribePocScreen(),
    );
  }
}

class TranscribePocScreen extends StatefulWidget {
  const TranscribePocScreen({super.key});

  @override
  State<TranscribePocScreen> createState() => _TranscribePocScreenState();
}

class _TranscribePocScreenState extends State<TranscribePocScreen> {
  final _whisperController = WhisperController();

  WhisperModel _selectedModel = WhisperModel.base;
  String? _audioPath;
  String? _audioName;
  bool _isBusy = false;
  String _status = '尚未選擇音檔';
  String _resultText = '';
  Duration? _elapsed;

  String _formatTimestamp(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

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

  Future<void> _pickAudioFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['m4a', 'mp3', 'wav'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() {
      _audioPath = path;
      _audioName = result!.files.single.name;
      _status = '已選擇: $_audioName';
      _resultText = '';
      _elapsed = null;
    });
  }

  Future<void> _runTranscription() async {
    final audioPath = _audioPath;
    if (audioPath == null || _isBusy) return;

    setState(() {
      _isBusy = true;
      _status = '下載/確認模型中 (${_selectedModel.modelName})...';
      _resultText = '';
      _elapsed = null;
    });

    final stopwatch = Stopwatch()..start();
    try {
      final safeAudioPath = await _sanitizedAudioPath(audioPath);
      debugPrint('[POC] audioPath=$audioPath safeAudioPath=$safeAudioPath '
          'model=${_selectedModel.modelName}');
      await _whisperController.downloadModel(_selectedModel);
      final modelPath = await _whisperController.getPath(_selectedModel);
      final modelFile = File(modelPath);
      debugPrint('[POC] modelPath=$modelPath exists=${modelFile.existsSync()} '
          'size=${modelFile.existsSync() ? modelFile.lengthSync() : 'n/a'}');

      setState(() => _status = '轉錄中 (${_selectedModel.modelName})...');

      final result = await _whisperController.transcribe(
        model: _selectedModel,
        audioPath: safeAudioPath,
        lang: 'zh',
        withSegments: true,
      );

      stopwatch.stop();
      final segments = result?.transcription.segments;
      debugPrint('[POC] result==null: ${result == null}');
      debugPrint('[POC] segments count: ${segments?.length}');
      debugPrint('[POC] transcription.text: "${result?.transcription.text}"');

      final formatted = (segments == null || segments.isEmpty)
          ? (result?.transcription.text ?? '(無結果)')
          : segments.map((s) => '[${_formatTimestamp(s.fromTs)}] ${s.text.trim()}').join('\n');

      setState(() {
        _elapsed = stopwatch.elapsed;
        _resultText = formatted;
        _status = '完成 (${_selectedModel.modelName})';
      });
    } catch (e, st) {
      stopwatch.stop();
      debugPrint('[POC] EXCEPTION: $e\n$st');
      setState(() {
        _elapsed = stopwatch.elapsed;
        _status = '失敗: $e';
      });
    } finally {
      setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('echonote - Whisper POC')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<WhisperModel>(
              segments: const [
                ButtonSegment(value: WhisperModel.base, label: Text('base')),
                ButtonSegment(value: WhisperModel.small, label: Text('small')),
              ],
              selected: {_selectedModel},
              onSelectionChanged: _isBusy
                  ? null
                  : (selection) => setState(() => _selectedModel = selection.first),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _isBusy ? null : _pickAudioFile,
              child: const Text('選擇音檔'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: (_audioPath == null || _isBusy) ? null : _runTranscription,
              child: _isBusy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('開始轉錄'),
            ),
            const SizedBox(height: 12),
            Text(_status),
            if (_elapsed != null) Text('耗時: ${_elapsed!.inSeconds} 秒'),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('逐字稿結果:', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton.icon(
                  onPressed: _resultText.isEmpty
                      ? null
                      : () {
                          Clipboard.setData(ClipboardData(text: _resultText));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已複製到剪貼簿')),
                          );
                        },
                  icon: const Icon(Icons.copy),
                  label: const Text('複製'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(_resultText),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
