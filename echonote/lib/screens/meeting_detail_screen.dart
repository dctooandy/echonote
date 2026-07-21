import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

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
    try {
      await _audioPlayer.seek(position);
      await _audioPlayer.play();
    } catch (e) {
      debugPrint('[Detail] seek/play failed: $e');
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
          bottom: const TabBar(
            tabs: [
              Tab(text: '摘要'),
              Tab(text: '待辦'),
              Tab(text: '逐字稿'),
              Tab(text: '結構化紀錄'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildSummaryTab(analysis),
            _buildTodosTab(analysis),
            _buildTranscriptTab(),
            _buildMinutesTab(analysis),
          ],
        ),
      ),
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
        StreamBuilder<PlayerState>(
          stream: _audioPlayer.playerStateStream,
          builder: (context, snapshot) {
            final playing = snapshot.data?.playing ?? false;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
                    iconSize: 36,
                    onPressed: () => playing ? _audioPlayer.pause() : _audioPlayer.play(),
                  ),
                  const Text('點下方逐字稿可跳到對應時間點播放'),
                ],
              ),
            );
          },
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
