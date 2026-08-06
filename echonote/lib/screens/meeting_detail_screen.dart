import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/recording.dart';
import '../services/analysis_service.dart';
import '../services/recording_store.dart';
import '../utils/format.dart';

class MeetingDetailScreen extends StatefulWidget {
  const MeetingDetailScreen({super.key, required this.recording});

  final Recording recording;

  @override
  State<MeetingDetailScreen> createState() => _MeetingDetailScreenState();
}

class _MeetingDetailScreenState extends State<MeetingDetailScreen> {
  final _audioPlayer = AudioPlayer();
  final _analysisService = AnalysisService();
  final _store = RecordingStore();
  bool _isAnalyzing = false;

  @override
  void initState() {
    super.initState();
    _loadAudio();
  }

  Future<void> _loadAudio() async {
    try {
      final path = await _store.resolveAudioPath(widget.recording);
      await _audioPlayer.setFilePath(path);
    } catch (e) {
      debugPrint('[Detail] setFilePath failed: $e');
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _seekAndPlay(Duration position) async {
    debugPrint('[Detail] seekAndPlay requested position=${position.inMilliseconds}ms');
    try {
      await _audioPlayer.seek(position);
      await _audioPlayer.play();
    } catch (e) {
      debugPrint('[Detail] seek/play failed: $e');
    }
  }

  void _toggleManualPlayback(bool playing) {
    if (playing) {
      _audioPlayer.pause();
    } else {
      _audioPlayer.play();
    }
  }

  /// Reflects an in-place edit to `widget.recording` immediately, then
  /// persists it in the background — edits are low-stakes local data, so
  /// there's no need to make the UI wait on the write finishing.
  void _persist() {
    setState(() {});
    _store.save(widget.recording);
  }

  Future<void> _runAnalysis() async {
    if (_isAnalyzing) return;
    setState(() => _isAnalyzing = true);
    try {
      final analysis = await _analysisService.analyze(widget.recording.segments);
      widget.recording.analysis = analysis;
      await _store.save(widget.recording);
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('分析失敗: $e')));
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已複製到剪貼簿')));
  }

  String get _transcriptText => widget.recording.segments
      .map((s) => '[${formatMs(s.startMs)}] ${s.text}')
      .join('\n');

  /// Writes the transcript to a temp .txt file and hands it to the OS share
  /// sheet — lets the user save it into Files, AirDrop it, send it via
  /// LINE/Email, etc., without echonote needing its own file-destination UI.
  Future<void> _exportTranscript() async {
    try {
      final dir = await getTemporaryDirectory();
      final safeName = widget.recording.displayTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file = File('${dir.path}/$safeName.txt');
      await file.writeAsString(_transcriptText);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], fileNameOverrides: ['$safeName.txt']),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('匯出失敗: $e')));
    }
  }

  Future<void> _editTodoTask(Todo todo) async {
    final controller = TextEditingController(text: todo.task);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('編輯待辦事項'),
        content: TextField(controller: controller, autofocus: true, maxLines: 3),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('儲存'),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      todo.task = result.trim();
      _persist();
    }
  }

  Future<void> _addAttendee(MeetingAnalysis analysis) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增與會者'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('新增'),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      analysis.attendees.add(result.trim());
      _persist();
    }
  }

  @override
  Widget build(BuildContext context) {
    final analysis = widget.recording.analysis;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.recording.displayTitle),
          actions: [
            if (analysis != null)
              IconButton(
                icon: _isAnalyzing
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                tooltip: '重新分析',
                onPressed: _isAnalyzing ? null : _runAnalysis,
              ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: '摘要'),
              Tab(text: '待辦'),
              Tab(text: '逐字稿'),
              Tab(text: '結構化紀錄'),
            ],
          ),
        ),
        body: Column(
          children: [
            _buildPlaybackBar(),
            Expanded(
              child: TabBarView(
                children: [
                  _buildSummaryTab(analysis),
                  _buildTodosTab(analysis),
                  _buildTranscriptTab(),
                  _buildMinutesTab(analysis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Playback controls shown above every tab (not just 逐字稿) — tapping a
  /// todo or agenda item to jump to its timestamp starts playback from
  /// whichever tab is open, so the pause control needs to be reachable from
  /// all of them, not just the transcript tab.
  Widget _buildPlaybackBar() {
    return StreamBuilder<PlayerState>(
      stream: _audioPlayer.playerStateStream,
      builder: (context, snapshot) {
        final playing = snapshot.data?.playing ?? false;
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
                  iconSize: 36,
                  onPressed: () => _toggleManualPlayback(playing),
                ),
                const Expanded(
                  child: Text(
                    '點擊逐字稿／待辦／議程項目可跳轉播放，隨時可在此暫停',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _analysisGate(MeetingAnalysis? analysis, Widget Function(MeetingAnalysis) builder) {
    if (analysis != null) return builder(analysis);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('尚未產出摘要/待辦/結構化紀錄'),
            const SizedBox(height: 16),
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
        ),
      ),
    );
  }

  Widget _buildSummaryTab(MeetingAnalysis? analysis) {
    return _analysisGate(analysis, (a) {
      final copyText = ([a.overview, ...a.keyPoints.map((p) => '• $p')]).join('\n');
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Text('摘要', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              IconButton(icon: const Icon(Icons.copy, size: 20), onPressed: () => _copy(copyText)),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(a.overview),
          const SizedBox(height: 8),
          for (final point in a.keyPoints) SelectableText('• $point'),
        ],
      );
    });
  }

  Widget _buildTodosTab(MeetingAnalysis? analysis) {
    return _analysisGate(analysis, (a) {
      if (a.todos.isEmpty) return const Center(child: Text('沒有待辦事項'));
      debugPrint('[Detail] todo timestamps: '
          '${a.todos.map((t) => t.sourceTimestampMs).toList()}');
      return ListView.builder(
        itemCount: a.todos.length,
        itemBuilder: (context, index) {
          final todo = a.todos[index];
          return ListTile(
            leading: Checkbox(
              value: todo.done,
              onChanged: (value) {
                todo.done = value ?? false;
                _persist();
              },
            ),
            title: Text(
              todo.task,
              style: todo.done ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
            ),
            subtitle: Text([
              if (todo.owner != null) '負責人: ${todo.owner}',
              if (todo.dueDate != null) '期限: ${todo.dueDate}',
            ].join('　')),
            onTap: todo.sourceTimestampMs != null
                ? () => _seekAndPlay(Duration(milliseconds: todo.sourceTimestampMs!))
                : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (todo.sourceTimestampMs != null) Text(formatMs(todo.sourceTimestampMs!)),
                IconButton(
                  icon: const Icon(Icons.edit, size: 18),
                  onPressed: () => _editTodoTask(todo),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () {
                    a.todos.removeAt(index);
                    _persist();
                  },
                ),
              ],
            ),
          );
        },
      );
    });
  }

  Widget _buildTranscriptTab() {
    final segments = widget.recording.segments;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                icon: const Icon(Icons.copy, size: 20),
                tooltip: '複製全部逐字稿',
                onPressed: segments.isEmpty ? null : () => _copy(_transcriptText),
              ),
              IconButton(
                icon: const Icon(Icons.ios_share, size: 20),
                tooltip: '匯出逐字稿',
                onPressed: segments.isEmpty ? null : _exportTranscript,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: segments.length,
            itemBuilder: (context, index) {
              final segment = segments[index];
              return ListTile(
                dense: true,
                leading: Text(formatMs(segment.startMs)),
                title: Text(segment.text),
                onTap: () => _seekAndPlay(Duration(milliseconds: segment.startMs)),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMinutesTab(MeetingAnalysis? analysis) {
    return _analysisGate(analysis, (a) {
      debugPrint('[Detail] agenda item timestamps: '
          '${a.agendaItems.map((i) => i.sourceTimestampMs).toList()}');
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(a.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final person in a.attendees)
                Chip(
                  label: Text(person),
                  onDeleted: () {
                    a.attendees.remove(person);
                    _persist();
                  },
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('新增'),
                onPressed: () => _addAttendee(a),
              ),
            ],
          ),
          const SizedBox(height: 16),
          for (final item in a.agendaItems)
            Card(
              child: ListTile(
                title: Text(item.topic),
                subtitle: Text([
                  item.discussion,
                  for (final decision in item.decisions) '決議: $decision',
                ].where((s) => s.isNotEmpty).join('\n')),
                isThreeLine: true,
                trailing:
                    item.sourceTimestampMs != null ? Text(formatMs(item.sourceTimestampMs!)) : null,
                onTap: item.sourceTimestampMs != null
                    ? () => _seekAndPlay(Duration(milliseconds: item.sourceTimestampMs!))
                    : null,
              ),
            ),
        ],
      );
    });
  }
}
