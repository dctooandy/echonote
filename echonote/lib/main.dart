import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const EchoNoteApp());
}

Future<Directory> _historyDir() async {
  final dir = await getApplicationDocumentsDirectory();
  final historyDir = Directory('${dir.path}/history');
  if (!await historyDir.exists()) await historyDir.create(recursive: true);
  return historyDir;
}

Future<Directory> _recordingsDir() async {
  final dir = await getApplicationDocumentsDirectory();
  final recDir = Directory('${dir.path}/recordings');
  if (!await recDir.exists()) await recDir.create(recursive: true);
  return recDir;
}

Future<void> _saveHistoryEntry(Map<String, dynamic> entry) async {
  final dir = await _historyDir();
  final file = File('${dir.path}/${entry['id']}.json');
  await file.writeAsString(jsonEncode(entry));
}

Future<List<Map<String, dynamic>>> _loadHistoryEntries() async {
  final dir = await _historyDir();
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
  final entries = <Map<String, dynamic>>[];
  for (final file in files) {
    try {
      entries.add(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[History] failed to read ${file.path}: $e');
    }
  }
  entries.sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
  return entries;
}

class EchoNoteApp extends StatelessWidget {
  const EchoNoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'echonote Whisper POC',
      debugShowCheckedModeBanner: false,
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
  final _audioPlayer = AudioPlayer();

  WhisperModel _selectedModel = WhisperModel.base;
  String? _audioPath;
  String? _audioName;
  bool _isBusy = false;
  String _status = '尚未選擇音檔';
  String _resultText = '';
  List<WhisperTranscribeSegment> _segments = [];
  Duration? _elapsed;
  bool _isAnalyzing = false;
  String? _currentHistoryId;

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _seekAndPlay(Duration position) async {
    try {
      await _audioPlayer.seek(position);
      await _audioPlayer.play();
    } catch (e) {
      debugPrint('[POC] seek/play failed: $e');
    }
  }

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
    try {
      await _audioPlayer.setFilePath(path);
    } catch (e) {
      debugPrint('[POC] setFilePath failed: $e');
    }
    setState(() {
      _audioPath = path;
      _audioName = result!.files.single.name;
      _status = '已選擇: $_audioName';
      _resultText = '';
      _segments = [];
      _elapsed = null;
      _currentHistoryId = null;
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

      String? historyId;
      if (segments != null && segments.isNotEmpty) {
        historyId = DateTime.now().millisecondsSinceEpoch.toString();
        final recDir = await _recordingsDir();
        final ext = audioPath.split('.').last;
        final persistedAudioPath = '${recDir.path}/$historyId.$ext';
        await File(safeAudioPath).copy(persistedAudioPath);
        await _saveHistoryEntry({
          'id': historyId,
          'audio_name': _audioName,
          'created_at': DateTime.now().toIso8601String(),
          'model': _selectedModel.modelName,
          'elapsed_seconds': stopwatch.elapsed.inSeconds,
          'audio_path': persistedAudioPath,
          'segments': segments
              .map((s) => {
                    'start_ms': s.fromTs.inMilliseconds,
                    'end_ms': s.toTs.inMilliseconds,
                    'text': s.text.trim(),
                  })
              .toList(),
          'analysis': null,
        });
      }

      setState(() {
        _elapsed = stopwatch.elapsed;
        _resultText = formatted;
        _segments = segments ?? [];
        _currentHistoryId = historyId;
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

  Future<void> _runAnalysis() async {
    if (_segments.isEmpty || _isAnalyzing) return;
    setState(() => _isAnalyzing = true);
    try {
      final payload = _segments
          .map((s) => {
                'start_ms': s.fromTs.inMilliseconds,
                'end_ms': s.toTs.inMilliseconds,
                'text': s.text.trim(),
              })
          .toList();
      final callable = FirebaseFunctions.instance.httpsCallable('analyzeMeeting');
      final result = await callable.call<Map<String, dynamic>>({'segments': payload});
      // The plugin returns nested Map<Object?, Object?> from the platform channel;
      // round-tripping through JSON normalizes it to plain Map<String, dynamic>.
      final analysis = jsonDecode(jsonEncode(result.data)) as Map<String, dynamic>;

      final historyId = _currentHistoryId;
      if (historyId != null) {
        final dir = await _historyDir();
        final file = File('${dir.path}/$historyId.json');
        if (await file.exists()) {
          final entry = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          entry['analysis'] = analysis;
          await file.writeAsString(jsonEncode(entry));
        }
      }

      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AnalysisResultScreen(analysis: analysis, onSeek: _seekAndPlay),
        ),
      );
    } catch (e, st) {
      debugPrint('[POC] analysis EXCEPTION: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('分析失敗: $e')));
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('echonote - Whisper POC'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '歷史紀錄',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HistoryListScreen()),
            ),
          ),
        ],
      ),
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
            if (_audioPath != null) ...[
              const SizedBox(height: 8),
              StreamBuilder<PlayerState>(
                stream: _audioPlayer.playerStateStream,
                builder: (context, snapshot) {
                  final playing = snapshot.data?.playing ?? false;
                  return Row(
                    children: [
                      IconButton(
                        icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
                        iconSize: 36,
                        onPressed: () => playing ? _audioPlayer.pause() : _audioPlayer.play(),
                      ),
                      const Text('點下方逐字稿可跳到對應時間點播放'),
                    ],
                  );
                },
              ),
            ],
            if (_segments.isNotEmpty) ...[
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: _isAnalyzing ? null : _runAnalysis,
                icon: _isAnalyzing
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: Text(_isAnalyzing ? '分析中...' : '產出摘要/待辦/紀錄'),
              ),
            ],
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
              child: _segments.isEmpty
                  ? SingleChildScrollView(child: SelectableText(_resultText))
                  : ListView.builder(
                      itemCount: _segments.length,
                      itemBuilder: (context, index) {
                        final segment = _segments[index];
                        return ListTile(
                          dense: true,
                          leading: Text(
                            _formatTimestamp(segment.fromTs),
                            style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                          ),
                          title: Text(segment.text.trim()),
                          onTap: () => _seekAndPlay(segment.fromTs),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatMs(int ms) {
  final d = Duration(milliseconds: ms);
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

class AnalysisResultScreen extends StatelessWidget {
  const AnalysisResultScreen({super.key, required this.analysis, required this.onSeek});

  final Map<String, dynamic> analysis;
  final void Function(Duration) onSeek;

  void _copy(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已複製到剪貼簿')));
  }

  Widget _sectionHeader(BuildContext context, String title, String copyText) {
    return Row(
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.copy, size: 20),
          tooltip: '複製$title',
          onPressed: () => _copy(context, copyText),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final summary = analysis['summary'] as Map<String, dynamic>? ?? {};
    final todos = analysis['todos'] as List<dynamic>? ?? [];
    final minutes = analysis['structured_minutes'] as Map<String, dynamic>? ?? {};
    final agendaItems = minutes['agenda_items'] as List<dynamic>? ?? [];
    final attendees = (minutes['attendees'] as List<dynamic>? ?? []).cast<String>();
    final keyPoints = (summary['key_points'] as List<dynamic>? ?? []).cast<String>();
    final overview = summary['overview'] as String? ?? '';
    final summaryCopyText =
        ([overview, ...keyPoints.map((p) => '• $p')]).join('\n');

    return Scaffold(
      appBar: AppBar(title: const Text('分析結果')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionHeader(context, '摘要', summaryCopyText),
          const SizedBox(height: 8),
          SelectableText(overview),
          const SizedBox(height: 8),
          for (final point in keyPoints) SelectableText('• $point'),
          const Divider(height: 32),
          Text('待辦事項', style: Theme.of(context).textTheme.titleLarge),
          if (todos.isEmpty) const Text('（無）'),
          for (final item in todos.cast<Map<String, dynamic>>())
            ListTile(
              leading: const Icon(Icons.check_box_outline_blank),
              title: Text(item['task'] as String? ?? ''),
              subtitle: Text([
                if (item['owner'] != null) '負責人: ${item['owner']}',
                if (item['due_date'] != null) '期限: ${item['due_date']}',
              ].join('　')),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (item['source_timestamp_ms'] != null)
                    Text(_formatMs(item['source_timestamp_ms'] as int)),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: '複製這則待辦',
                    onPressed: () => _copy(context, [
                      item['task'] as String? ?? '',
                      if (item['owner'] != null) '負責人: ${item['owner']}',
                      if (item['due_date'] != null) '期限: ${item['due_date']}',
                    ].join('\n')),
                  ),
                ],
              ),
              onTap: item['source_timestamp_ms'] != null
                  ? () => onSeek(Duration(milliseconds: item['source_timestamp_ms'] as int))
                  : null,
            ),
          const Divider(height: 32),
          Text('結構化會議紀錄', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(minutes['title'] as String? ?? '', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (attendees.isNotEmpty)
            Wrap(
              spacing: 8,
              children: [for (final person in attendees) Chip(label: Text(person))],
            ),
          const SizedBox(height: 8),
          for (final item in agendaItems.cast<Map<String, dynamic>>())
            Card(
              child: ListTile(
                title: Text(item['topic'] as String? ?? ''),
                subtitle: Text([
                  item['discussion'] as String? ?? '',
                  for (final decision in (item['decisions'] as List<dynamic>? ?? []))
                    '決議: $decision',
                ].where((s) => s.isNotEmpty).join('\n')),
                isThreeLine: true,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (item['source_timestamp_ms'] != null)
                      Text(_formatMs(item['source_timestamp_ms'] as int)),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: '複製這個議程項目',
                      onPressed: () => _copy(context, [
                        item['topic'] as String? ?? '',
                        item['discussion'] as String? ?? '',
                        for (final decision in (item['decisions'] as List<dynamic>? ?? []))
                          '決議: $decision',
                      ].where((s) => s.isNotEmpty).join('\n')),
                    ),
                  ],
                ),
                onTap: item['source_timestamp_ms'] != null
                    ? () => onSeek(Duration(milliseconds: item['source_timestamp_ms'] as int))
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

class HistoryListScreen extends StatelessWidget {
  const HistoryListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('歷史紀錄')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _loadHistoryEntries(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snapshot.data!;
          if (entries.isEmpty) {
            return const Center(child: Text('還沒有任何紀錄'));
          }
          return ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              final hasAnalysis = entry['analysis'] != null;
              return ListTile(
                leading: Icon(hasAnalysis ? Icons.check_circle : Icons.description_outlined),
                title: Text(entry['audio_name'] as String? ?? '未命名'),
                subtitle: Text(
                  '${entry['created_at']}　模型: ${entry['model']}　耗時: ${entry['elapsed_seconds']}秒',
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => HistoryDetailScreen(entry: entry)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class HistoryDetailScreen extends StatefulWidget {
  const HistoryDetailScreen({super.key, required this.entry});

  final Map<String, dynamic> entry;

  @override
  State<HistoryDetailScreen> createState() => _HistoryDetailScreenState();
}

class _HistoryDetailScreenState extends State<HistoryDetailScreen> {
  final _audioPlayer = AudioPlayer();
  bool _isAnalyzing = false;
  Map<String, dynamic>? _analysis;

  @override
  void initState() {
    super.initState();
    _analysis = widget.entry['analysis'] as Map<String, dynamic>?;
    _loadAudio();
  }

  Future<void> _loadAudio() async {
    try {
      await _audioPlayer.setFilePath(widget.entry['audio_path'] as String);
    } catch (e) {
      debugPrint('[History] setFilePath failed: $e');
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _seekAndPlay(Duration position) async {
    try {
      await _audioPlayer.seek(position);
      await _audioPlayer.play();
    } catch (e) {
      debugPrint('[History] seek/play failed: $e');
    }
  }

  Future<void> _runAnalysis() async {
    if (_isAnalyzing) return;
    setState(() => _isAnalyzing = true);
    try {
      final segments = (widget.entry['segments'] as List<dynamic>).cast<Map<String, dynamic>>();
      final callable = FirebaseFunctions.instance.httpsCallable('analyzeMeeting');
      final result = await callable.call<Map<String, dynamic>>({'segments': segments});
      final analysis = jsonDecode(jsonEncode(result.data)) as Map<String, dynamic>;

      final dir = await _historyDir();
      final file = File('${dir.path}/${widget.entry['id']}.json');
      final updatedEntry = Map<String, dynamic>.from(widget.entry)..['analysis'] = analysis;
      await file.writeAsString(jsonEncode(updatedEntry));

      if (!mounted) return;
      setState(() => _analysis = analysis);
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AnalysisResultScreen(analysis: analysis, onSeek: _seekAndPlay),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('分析失敗: $e')));
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final segments = (widget.entry['segments'] as List<dynamic>).cast<Map<String, dynamic>>();
    return Scaffold(
      appBar: AppBar(title: Text(widget.entry['audio_name'] as String? ?? '歷史紀錄')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StreamBuilder<PlayerState>(
              stream: _audioPlayer.playerStateStream,
              builder: (context, snapshot) {
                final playing = snapshot.data?.playing ?? false;
                return Row(
                  children: [
                    IconButton(
                      icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
                      iconSize: 36,
                      onPressed: () => playing ? _audioPlayer.pause() : _audioPlayer.play(),
                    ),
                    const Text('點下方逐字稿可跳到對應時間點播放'),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _isAnalyzing
                  ? null
                  : (_analysis != null
                      ? () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  AnalysisResultScreen(analysis: _analysis!, onSeek: _seekAndPlay),
                            ),
                          )
                      : _runAnalysis),
              icon: _isAnalyzing
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_analysis != null ? Icons.visibility : Icons.auto_awesome),
              label: Text(
                _isAnalyzing ? '分析中...' : (_analysis != null ? '查看分析結果' : '產出摘要/待辦/紀錄'),
              ),
            ),
            const SizedBox(height: 12),
            const Text('逐字稿', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: segments.length,
                itemBuilder: (context, index) {
                  final segment = segments[index];
                  final startMs = segment['start_ms'] as int;
                  return ListTile(
                    dense: true,
                    leading: Text(_formatMs(startMs)),
                    title: Text(segment['text'] as String? ?? ''),
                    onTap: () => _seekAndPlay(Duration(milliseconds: startMs)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
