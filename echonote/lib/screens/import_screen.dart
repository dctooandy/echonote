import 'dart:io';

import 'package:flutter/material.dart';

import '../models/recording.dart';
import '../services/recording_store.dart';
import '../services/recording_transcriber.dart';
import '../services/transcription_service.dart';
import 'meeting_detail_screen.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key, required this.audioPath, required this.audioName});

  final String audioPath;
  final String audioName;

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final _store = RecordingStore();
  late final _transcriber = RecordingTranscriber(store: _store);

  int _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    File? copiedAudio;
    try {
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      final recDir = await _store.recordingsDir();
      final ext = widget.audioPath.split('.').last;
      final audioFileName = '$id.$ext';
      copiedAudio = await File(widget.audioPath).copy('${recDir.path}/$audioFileName');

      final recording = Recording(
        id: id,
        audioName: widget.audioName,
        createdAt: DateTime.now(),
        model: kWhisperModel.modelName,
        elapsedSeconds: 0,
        audioFileName: audioFileName,
        segments: [],
        source: RecordingSource.imported,
      );
      // Saves the recording only once it has a transcript.
      await _transcriber.transcribe(
        recording,
        onProgress: (percent) {
          if (mounted) setState(() => _progress = percent);
        },
      );

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => MeetingDetailScreen(recording: recording)),
      );
    } catch (e) {
      // A failed import leaves nothing behind (unlike a live recording, the
      // original file is still wherever the user picked it from).
      try {
        await copiedAudio?.delete();
      } catch (_) {}
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('轉錄中')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _error != null ? _buildError() : _buildProgress(),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, size: 48, color: Colors.red),
        const SizedBox(height: 16),
        Text(_error!, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        ElevatedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('返回')),
      ],
    );
  }

  Widget _buildProgress() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.audioName, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        CircularProgressIndicator(value: _progress > 0 ? _progress / 100 : null),
        const SizedBox(height: 16),
        Text(_progress > 0 ? '轉錄中… $_progress%' : '準備中…'),
        const SizedBox(height: 8),
        const Text('請保持 App 開啟直到轉錄完成', style: TextStyle(color: Colors.grey)),
      ],
    );
  }
}
