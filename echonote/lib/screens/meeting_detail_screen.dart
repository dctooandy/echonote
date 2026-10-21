import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/recording.dart';
import '../services/analysis_service.dart';
import '../services/glossary_store.dart';
import '../services/recording_store.dart';
import '../services/recording_transcriber.dart';
import '../utils/format.dart';
import '../widgets/confirm_delete_dialog.dart';

class MeetingDetailScreen extends StatefulWidget {
  const MeetingDetailScreen({super.key, required this.recording});

  final Recording recording;

  @override
  State<MeetingDetailScreen> createState() => _MeetingDetailScreenState();
}

class _MeetingDetailScreenState extends State<MeetingDetailScreen> {
  final _audioPlayer = AudioPlayer();
  final _analysisService = AnalysisService();
  final _glossary = GlossaryStore();
  final _store = RecordingStore();
  late final _transcriber = RecordingTranscriber(store: _store);
  bool _isAnalyzing = false;
  bool _isTranscribing = false;
  int _transcribeProgress = 0;

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
    if (!AnalysisService.available) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Platform.isAndroid ? 'Android 版尚未支援分析' : '分析服務無法使用')),
      );
      return;
    }
    setState(() => _isAnalyzing = true);
    try {
      // A corrupt glossary loads as empty: analyze without it.
      final glossary = (await _glossary.load()).terms.map((t) => t.term).toList();
      final analysis = await _analysisService.analyze(
        widget.recording.segments,
        glossary: glossary,
        notes: widget.recording.notes,
      );
      widget.recording
        ..analysis = analysis
        ..transcriptStaleAnalysis = false;
      await _store.save(widget.recording);
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('分析失敗: $e')));
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  /// For a recording saved without a transcript (live recording whose
  /// offline pass failed or found nothing, or was cut short by backgrounding).
  Future<void> _retranscribe() async {
    if (_isTranscribing) return;
    setState(() {
      _isTranscribing = true;
      _transcribeProgress = 0;
    });
    try {
      await _transcriber.transcribe(
        widget.recording,
        onProgress: (percent) {
          if (mounted) setState(() => _transcribeProgress = percent);
        },
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('轉錄失敗: $e')));
    } finally {
      if (mounted) setState(() => _isTranscribing = false);
    }
  }

  Future<void> _delete() async {
    if (!await confirmDeleteRecording(context, widget.recording)) return;
    // The player is disposed when this screen pops; no need to stop it first
    // (and an unloaded player's stop() may never complete).
    try {
      await _store.delete(widget.recording);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('刪除失敗: $e')));
      return;
    }
    if (mounted) Navigator.of(context).pop();
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

  /// Where the user is in the recording, for a new note.
  int get _positionMs => _audioPlayer.position.inMilliseconds;

  void _showSnack(String message, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  void _addStar() {
    final ms = _positionMs;
    final notes = widget.recording.notes;
    // Repeated taps within a second are one mark.
    final duplicate = notes.any(
      (n) => n.kind == UserNoteKind.star && (n.timestampMs - ms).abs() < 1000,
    );
    if (!duplicate) {
      notes.add(UserNote(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        timestampMs: ms,
        kind: UserNoteKind.star,
        createdAt: DateTime.now(),
      ));
      _persist();
    }
    _showSnack('已標記 ${formatMs(ms)}');
  }

  Future<void> _addTextNote() async {
    // Taken before the dialog opens: the note is about what was just heard,
    // not about where playback is once the user finishes typing.
    final ms = _positionMs;
    final text = await _promptNoteText(title: '筆記 ${formatMs(ms)}');
    if (text == null) return;
    widget.recording.notes.add(UserNote(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      timestampMs: ms,
      kind: UserNoteKind.text,
      text: text,
      createdAt: DateTime.now(),
    ));
    _persist();
  }

  /// Text notes only: a ★ has no text, and the timestamp is fixed (delete
  /// and re-add to move it).
  Future<void> _editNote(UserNote note) async {
    final text = await _promptNoteText(title: '編輯筆記 ${formatMs(note.timestampMs)}', initial: note.text);
    if (text == null) return;
    note.text = text;
    _persist();
  }

  void _deleteNote(UserNote note) {
    final contexts = widget.recording.analysis?.highlightContexts;
    final aiContext = contexts?.remove(note.id);
    widget.recording.notes.remove(note);
    _persist();
    _showSnack(
      '已刪除${note.kind == UserNoteKind.star ? '標記' : '筆記'}',
      action: SnackBarAction(
        label: '復原',
        onPressed: () {
          widget.recording.notes.add(note);
          if (aiContext != null) contexts![note.id] = aiContext;
          _persist();
        },
      ),
    );
  }

  /// Returns the trimmed text, or null when cancelled or left empty.
  Future<String?> _promptNoteText({required String title, String? initial}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(hintText: '這裡的重點是…'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('儲存'),
          ),
        ],
      ),
    );
    final text = result?.trim();
    return (text == null || text.isEmpty) ? null : text;
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
            if (analysis != null && widget.recording.isTranscribed)
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
            PopupMenuButton<String>(
              // Not while a transcription/analysis is about to write back
              // into this recording.
              enabled: !_isAnalyzing && !_isTranscribing,
              onSelected: (value) {
                if (value == 'delete') _delete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading: Icon(Icons.delete_outline, color: Colors.red),
                    title: Text('刪除', style: TextStyle(color: Colors.red)),
                  ),
                ),
              ],
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
                IconButton(
                  icon: const Icon(Icons.star_outline),
                  tooltip: '標記重點',
                  onPressed: _addStar,
                ),
                IconButton(
                  icon: const Icon(Icons.edit_note),
                  tooltip: '新增筆記',
                  onPressed: _addTextNote,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildUntranscribed() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('尚未轉錄'),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _isTranscribing ? null : _retranscribe,
              icon: _isTranscribing
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.subtitles_outlined),
              label: Text(
                _isTranscribing
                    ? (_transcribeProgress > 0 ? '轉錄中… $_transcribeProgress%' : '準備中…')
                    : '重新轉錄',
              ),
            ),
            if (_isTranscribing) ...[
              const SizedBox(height: 8),
              const Text('請保持 App 開啟直到轉錄完成', style: TextStyle(color: Colors.grey)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _analysisGate(MeetingAnalysis? analysis, Widget Function(MeetingAnalysis) builder) {
    // Analysis needs a transcript; offer transcription first.
    if (!widget.recording.isTranscribed) return _buildUntranscribed();
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

  /// The user's notes sit above the analysis and show without one: they
  /// are the user's own, not AI output.
  Widget _buildSummaryTab(MeetingAnalysis? analysis) {
    final summary = _buildSummary(analysis);
    if (widget.recording.notes.isEmpty) return summary;
    return Column(
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.3),
          child: _buildNotesSection(),
        ),
        const Divider(height: 1),
        Expanded(child: summary),
      ],
    );
  }

  Widget _buildNotesSection() {
    final notes = [...widget.recording.notes]..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    final analysis = widget.recording.analysis;
    final contexts = analysis?.highlightContexts ?? const {};
    // Added after the analysis (or skipped by it): re-analysis fills them in.
    final missing = analysis == null ? 0 : notes.where((n) => !contexts.containsKey(n.id)).length;
    final theme = Theme.of(context);
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('你的重點', style: theme.textTheme.titleMedium),
        ),
        if (missing > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              '有 $missing 筆重點還沒有 AI 補充說明，重新分析可補上',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        for (final note in notes)
          ListTile(
            dense: true,
            leading: Icon(note.kind == UserNoteKind.star ? Icons.star : Icons.notes),
            title: Text(note.kind == UserNoteKind.star ? '重點標記' : note.text ?? ''),
            // The user's words above, the AI's reading below — styled apart
            // so one is never mistaken for the other.
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(formatMs(note.timestampMs)),
                if (contexts[note.id] case final aiContext?)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.auto_awesome, size: 14, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            aiContext,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontStyle: FontStyle.italic,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            onTap: () => _seekAndPlay(Duration(milliseconds: note.timestampMs)),
            trailing: PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') _editNote(note);
                if (value == 'delete') _deleteNote(note);
              },
              itemBuilder: (_) => [
                if (note.kind == UserNoteKind.text)
                  const PopupMenuItem(value: 'edit', child: Text('編輯')),
                const PopupMenuItem(value: 'delete', child: Text('刪除')),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSummary(MeetingAnalysis? analysis) {
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
    if (!widget.recording.isTranscribed) return _buildUntranscribed();
    // Same lookup the analysis uses, so a marker sits on the line the AI
    // was pointed at.
    final notesBySegment = <int, List<UserNote>>{};
    for (final note in widget.recording.notes) {
      notesBySegment.putIfAbsent(segmentIndexFor(note.timestampMs, segments), () => []).add(note);
    }
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
              final notes = notesBySegment[index] ?? const [];
              return ListTile(
                dense: true,
                leading: Text(formatMs(segment.startMs)),
                title: Text(segment.text),
                trailing: notes.isEmpty
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final note in notes)
                            Icon(
                              note.kind == UserNoteKind.star ? Icons.star : Icons.notes,
                              size: 18,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                        ],
                      ),
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
