import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/glossary.dart';
import '../models/recording.dart';
import '../services/analysis_errors.dart';
import '../services/analysis_service.dart';
import '../services/app_settings.dart';
import '../services/correction_learning.dart';
import '../services/glossary_store.dart';
import '../services/meeting_chain.dart';
import '../services/meeting_html.dart';
import '../services/recording_store.dart';
import '../services/recording_transcriber.dart';
import '../services/screen_awake.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import '../widgets/confirm_delete_dialog.dart';
import '../widgets/glossary_term_dialog.dart';
import '../widgets/round_icon_button.dart';

class MeetingDetailScreen extends StatefulWidget {
  const MeetingDetailScreen({
    super.key,
    required this.recording,
    this.store,
    this.analysisService,
    this.glossary,
    this.shareFile,
  });

  final Recording recording;

  /// For tests; the app's on-disk stores and the cloud service by default.
  final RecordingStore? store;
  final AnalysisService? analysisService;
  final GlossaryStore? glossary;

  /// Hands a written file to the OS share sheet; tests swap it out.
  final Future<void> Function(String path, String fileName)? shareFile;

  @override
  State<MeetingDetailScreen> createState() => _MeetingDetailScreenState();
}

class _MeetingDetailScreenState extends State<MeetingDetailScreen> {
  final _audioPlayer = AudioPlayer();
  late final _analysisService = widget.analysisService ?? AnalysisService();
  late final _glossary = widget.glossary ?? GlossaryStore();
  late final _store = widget.store ?? RecordingStore();
  late final _transcriber = RecordingTranscriber(store: _store);
  bool _isAnalyzing = false;

  /// Seconds since the running analysis started: Claude gives no progress,
  /// so the banner shows time passed instead.
  int _analysisSeconds = 0;
  Timer? _analysisTimer;
  bool _isTranscribing = false;
  int _transcribeProgress = 0;

  /// Every saved meeting, to resolve and pick the one this follows; null
  /// until loaded.
  List<Recording>? _all;

  @override
  void initState() {
    super.initState();
    _loadAudio();
    _loadAll();
  }

  Future<void> _loadAll() async {
    final all = await _store.loadAll();
    if (mounted) setState(() => _all = all);
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
    _analysisTimer?.cancel();
    ScreenAwake.instance.release(this);
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(Platform.isAndroid ? 'Android 版尚未支援分析' : '分析服務無法使用')));
      return;
    }
    setState(() {
      _isAnalyzing = true;
      _analysisSeconds = 0;
    });
    _analysisTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _analysisSeconds++);
    });
    try {
      // A corrupt glossary loads as empty: analyze without it.
      final glossary = (await _glossary.load()).terms.map((t) => t.term).toList();
      final all = await _store.loadAll();
      final analysis = await _analysisService.analyze(
        widget.recording.segments,
        glossary: glossary,
        notes: widget.recording.notes,
        previous: previousChain(widget.recording, all),
      );
      widget.recording
        ..analysis = analysis
        ..transcriptStaleAnalysis = false
        ..previousChangedSinceAnalysis = false;
      await _store.save(widget.recording);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('分析完成，內容已更新')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(analysisErrorMessage(e))));
    } finally {
      _analysisTimer?.cancel();
      _analysisTimer = null;
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  /// A new analysis replaces the old one whole, todo ticks included, and
  /// calls the cloud service, so ask first (spec feature-dark-theme,
  /// decision 1).
  Future<void> _confirmReanalyze() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新分析？'),
        content: const Text('會用目前的逐字稿重新產生摘要、待辦和結構化紀錄，取代現在的結果，待辦的勾選也會重來。\n\n你的重點不受影響。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('重新分析')),
        ],
      ),
    );
    if (ok == true) await _runAnalysis();
  }

  /// Re-running a transcript that exists replaces it, edits included, so
  /// ask first.
  Future<void> _confirmRetranscribe() async {
    final edited = widget.recording.segments.where((s) => s.edited).length;
    final hasAnalysis = widget.recording.analysis != null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('用目前詞庫重新轉錄？'),
        content: Text(
          [
            if (edited > 0) '你修改過的 $edited 處逐字稿會被覆蓋。' else '目前的逐字稿會被取代。',
            if (hasAnalysis) '分析結果會保留，但可能和新的逐字稿對不上，之後可以重新分析。',
            '你的重點不受影響。轉錄期間請保持 App 開啟。',
          ].join('\n\n'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('重新轉錄')),
        ],
      ),
    );
    if (ok == true) await _retranscribe();
  }

  /// Transcribes a recording saved without a transcript (live recording
  /// whose offline pass failed or found nothing, or was cut short by
  /// backgrounding), or replaces an existing one with the current glossary.
  Future<void> _retranscribe() async {
    if (_isTranscribing) return;
    setState(() {
      _isTranscribing = true;
      _transcribeProgress = 0;
    });
    // Transcription only runs in the foreground (spec
    // feature-keep-screen-awake).
    ScreenAwake.instance.hold(this);
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
      ScreenAwake.instance.release(this);
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

  String get _transcriptText =>
      widget.recording.segments.map((s) => '[${formatMs(s.startMs)}] ${s.text}').join('\n');

  Future<void> _shareFile(String path, String fileName) =>
      widget.shareFile?.call(path, fileName) ??
      SharePlus.instance.share(ShareParams(files: [XFile(path)], fileNameOverrides: [fileName]));

  /// The minutes as one HTML file, for people without the app (spec
  /// feature-html-export).
  Future<void> _exportMinutes() async {
    try {
      final all = _all ?? await _store.loadAll();
      final html = buildMeetingHtml(
        widget.recording,
        previous: previousOf(widget.recording, all),
        exportedAt: DateTime.now(),
      );
      final fileName = meetingHtmlFileName(widget.recording);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(html);
      await _shareFile(file.path, fileName);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('匯出失敗: $e')));
    }
  }

  /// Writes the transcript to a temp .txt file and hands it to the OS share
  /// sheet — lets the user save it into Files, AirDrop it, send it via
  /// LINE/Email, etc., without echonote needing its own file-destination UI.
  Future<void> _exportTranscript() async {
    try {
      final dir = await getTemporaryDirectory();
      final safeName = safeFileName(widget.recording.displayTitle);
      final file = File('${dir.path}/$safeName.txt');
      await file.writeAsString(_transcriptText);
      await _shareFile(file.path, '$safeName.txt');
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
    if (addStarNote(widget.recording.notes, ms)) _persist();
    _showSnack('已標記 ${formatMs(ms)}');
  }

  Future<void> _addTextNote() async {
    // Taken before the dialog opens: the note is about what was just heard,
    // not about where playback is once the user finishes typing.
    final ms = _positionMs;
    final text = await _promptNoteText(title: '筆記 ${formatMs(ms)}');
    if (text == null) return;
    widget.recording.notes.add(
      UserNote(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        timestampMs: ms,
        kind: UserNoteKind.text,
        text: text,
        createdAt: DateTime.now(),
      ),
    );
    _persist();
  }

  /// Text notes only: a ★ has no text, and the timestamp is fixed (delete
  /// and re-add to move it).
  Future<void> _editNote(UserNote note) async {
    final text = await _promptNoteText(
      title: '編輯筆記 ${formatMs(note.timestampMs)}',
      initial: note.text,
    );
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

  /// Tap seeks, so editing is on long press.
  Future<void> _editSegment(TranscriptSegment segment) async {
    final controller = TextEditingController(text: segment.text);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('修改逐字稿 ${formatMs(segment.startMs)}'),
        content: TextField(controller: controller, autofocus: true, maxLines: 4),
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
    if (text == null || text.isEmpty || text == segment.text) return;
    final replacement = detectReplacement(segment.text, text);
    segment
      ..text = text
      ..edited = true;
    _persist();
    if (replacement != null && !widget.recording.dismissedReplacements.contains(replacement.key)) {
      await _offerToLearn(replacement, segment);
      return;
    }
    // Only a single 2–10 character replacement is offered automatically;
    // otherwise say the edit was saved and leave adding a term to the user,
    // so a missing prompt never looks like a broken feature.
    _showSnack(
      '已修改',
      action: SnackBarAction(label: '加入詞庫', onPressed: _addTermManually),
    );
  }

  Future<void> _addTermManually() async {
    final loaded = await _glossary.load();
    if (!mounted) return;
    if (loaded.isCorrupt) {
      _showSnack('${const GlossaryCorruptException()}');
      return;
    }
    final term = await showDialog<String>(
      context: context,
      builder: (context) => GlossaryTermDialog(title: '加入詞庫', others: loaded.terms),
    );
    if (term == null) return;
    final GlossaryTermError? error;
    try {
      error = await _glossary.add(term);
    } on GlossaryCorruptException catch (e) {
      if (mounted) _showSnack('$e');
      return;
    }
    if (!mounted) return;
    _showSnack(error?.message ?? '已把「$term」加入詞庫');
  }

  /// Asks whether a correction is a term worth learning. The detected span
  /// may be part of a word (`太基電` → `台積電` diffs to `太基` → `台積`), so the
  /// term is editable and the misspelling widens with it.
  Future<void> _offerToLearn(Replacement detected, TranscriptSegment edited) async {
    final segments = widget.recording.segments;
    final answer = await showDialog<({_LearnChoice choice, Replacement expanded})>(
      context: context,
      builder: (context) => _LearnDialog(
        detected: detected,
        countOthers: (misspelling) => countOccurrences(segments, misspelling, except: edited),
      ),
    );
    if (answer == null || !mounted) return;
    final (:choice, :expanded) = answer;

    if (choice == _LearnChoice.dismiss) {
      widget.recording.dismissedReplacements.add(detected.key);
      _persist();
      return;
    }

    final GlossaryTermError? error;
    try {
      error = await _glossary.learn(expanded.after, expanded.before);
    } on GlossaryCorruptException catch (e) {
      _showSnack('$e');
      return;
    }
    if (!mounted) return;
    if (error != null) {
      _showSnack(error.message);
      return;
    }

    var fixed = 0;
    if (choice == _LearnChoice.learnAndApply) {
      fixed = replaceInSegments(segments, expanded.before, expanded.after, except: edited);
      if (fixed > 0 && widget.recording.analysis != null) {
        widget.recording.transcriptStaleAnalysis = true;
      }
      _persist();
    }
    _showSnack(fixed > 0 ? '已加入詞庫，並修正 $fixed 處' : '已加入詞庫');
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
    final busy = _isAnalyzing || _isTranscribing;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.recording.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          // Seldom used and costly to hit by mistake, so up here, out of the
          // thumb's way, behind one menu so the title keeps its room; each
          // asks first (spec feature-dark-theme; menu since
          // feature-cross-meeting-memory).
          actions: [
            PopupMenuButton<_MoreAction>(
              tooltip: '更多',
              enabled: !busy,
              icon: const Icon(Icons.more_horiz, size: 20),
              style: IconButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
                fixedSize: const Size.square(38),
                minimumSize: const Size.square(38),
                padding: EdgeInsets.zero,
              ),
              onSelected: (action) => switch (action) {
                _MoreAction.previous => _pickPrevious(),
                _MoreAction.export => _exportMinutes(),
                _MoreAction.reanalyze => _confirmReanalyze(),
                _MoreAction.retranscribe => _confirmRetranscribe(),
                _MoreAction.delete => _delete(),
              },
              itemBuilder: (context) {
                final error = Theme.of(context).colorScheme.error;
                PopupMenuItem<_MoreAction> item(
                  _MoreAction value,
                  IconData icon,
                  String label, {
                  Color? color,
                  bool enabled = true,
                }) =>
                    PopupMenuItem(
                      value: value,
                      enabled: enabled,
                      child: Row(
                        children: [
                          Icon(icon, size: 20, color: color),
                          const SizedBox(width: 12),
                          Text(label, style: TextStyle(color: color)),
                        ],
                      ),
                    );
                return [
                  item(_MoreAction.previous, Icons.link, '接續上一場'),
                  item(_MoreAction.export, Icons.ios_share, '匯出會議紀錄', enabled: analysis != null),
                  if (analysis != null && widget.recording.isTranscribed)
                    item(_MoreAction.reanalyze, Icons.auto_awesome, '重新分析'),
                  if (widget.recording.isTranscribed)
                    item(_MoreAction.retranscribe, Icons.subtitles_outlined, '用目前詞庫重新轉錄'),
                  item(_MoreAction.delete, Icons.delete_outline, '刪除', color: error),
                ];
              },
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: Column(
          children: [
            ?_buildChainCard(),
            // The untranscribed view has its own progress; this covers
            // replacing an existing transcript.
            if (_isTranscribing && widget.recording.isTranscribed) _buildRetranscribeProgress(),
            if (_isAnalyzing) _buildAnalysisProgress(),
            if (analysis != null &&
                (widget.recording.transcriptStaleAnalysis || widget.recording.previousChangedSinceAnalysis) &&
                !_isTranscribing &&
                !_isAnalyzing)
              _buildStaleAnalysisBanner(),
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
            _buildPlaybackBar(),
          ],
        ),
        // Tabs at the bottom, within the thumb's reach; swiping still works.
        bottomNavigationBar: const _TabNavigationBar(),
      ),
    );
  }

  /// Playback controls shown under every tab (not just 逐字稿) — tapping a
  /// todo or agenda item to jump to its timestamp starts playback from
  /// whichever tab is open, so the pause control needs to be reachable from
  /// all of them. A pill just above the tabs, play under the thumb.
  Widget _buildPlaybackBar() {
    final scheme = Theme.of(context).colorScheme;
    final leftHanded = AppSettingsScope.of(context).handedness == Handedness.left;
    return StreamBuilder<PlayerState>(
      stream: _audioPlayer.playerStateStream,
      builder: (context, snapshot) {
        final playing = snapshot.data?.playing ?? false;
        final children = [
          RoundIconButton(icon: Icons.star_outline, tooltip: '標記重點', onPressed: _addStar),
          RoundIconButton(icon: Icons.edit_note, tooltip: '新增筆記', onPressed: _addTextNote),
          Expanded(
            child: StreamBuilder<Duration>(
              stream: _audioPlayer.positionStream,
              builder: (context, position) {
                final total = _audioPlayer.duration?.inMilliseconds ?? widget.recording.durationMs;
                return Text(
                  [
                    formatMs(position.data?.inMilliseconds ?? 0),
                    if (total != null) formatMs(total),
                  ].join(' / '),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                );
              },
            ),
          ),
          IconButton.filled(
            icon: Icon(playing ? Icons.pause : Icons.play_arrow, size: 26),
            tooltip: playing ? '暫停' : '播放',
            style: IconButton.styleFrom(fixedSize: const Size.square(44)),
            onPressed: () => _toggleManualPlayback(playing),
          ),
        ];
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: 0.25),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(children: leftHanded ? children.reversed.toList() : children),
          ),
        );
      },
    );
  }

  Widget _buildRetranscribeProgress() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_transcribeProgress > 0 ? '重新轉錄中… $_transcribeProgress%（請保持 App 開啟）' : '準備重新轉錄…'),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: _transcribeProgress > 0 ? _transcribeProgress / 100 : null,
          ),
        ],
      ),
    );
  }

  /// Same place and look as re-transcription, on every tab, so any long
  /// action reads the same; the old results stay readable meanwhile.
  Widget _buildAnalysisProgress() {
    final theme = Theme.of(context);
    final again = widget.recording.analysis != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(again ? '正在重新分析…' : '正在分析…')),
              Text(
                '已 ${formatLength(_analysisSeconds * 1000)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const LinearProgressIndicator(),
          const SizedBox(height: 4),
          Text(
            again ? '通常需要半分鐘，可以先看其他分頁' : '通常需要半分鐘',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// Shown on every tab: todos and minutes go stale as much as the summary.
  Widget _buildStaleAnalysisBanner() {
    final colors = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: colors.amberSoft,
        borderRadius: BorderRadius.circular(kCardRadius),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 20, color: colors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.recording.transcriptStaleAnalysis
                  ? '逐字稿已更新，分析結果可能過時'
                  : '接續的會議變了，重新分析才會更新「與上次相比」',
              style: TextStyle(color: colors.amber),
            ),
          ),
          FilledButton(
            onPressed: _isAnalyzing ? null : _confirmReanalyze,
            style: FilledButton.styleFrom(
              backgroundColor: colors.amber,
              foregroundColor: Theme.of(context).colorScheme.surface,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('重新分析'),
          ),
        ],
      ),
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
              Text(
                '請保持 App 開啟直到轉錄完成',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
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
        if (widget.recording.notes.isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.3),
            child: _buildNotesSection(),
          ),
        Expanded(child: summary),
      ],
    );
  }

  /// Opened by a tap; closed again on every visit (spec
  /// feature-chain-links, decision 11).
  bool _chainOpen = false;

  /// What this meeting follows and what follows it, above every tab (spec
  /// feature-chain-links, decision 7); null for a meeting with no links (or
  /// while the list loads).
  Widget? _buildChainCard() {
    final all = _all;
    if (all == null) return null;
    final followsOne = widget.recording.previousRecordingId != null;
    final previous = previousOf(widget.recording, all);
    final followers = followersOf(widget.recording, all);
    if (!followsOne && followers.isEmpty) return null;
    final scheme = Theme.of(context).colorScheme;
    final series = seriesOf(all).where((s) => s.contains(widget.recording)).firstOrNull;
    final color = series == null ? scheme.primary : seriesColor(context, series.colorIndex);
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    final summary = [
      if (followsOne) previous == null ? '接續的會議已刪除' : '↩ 接續：${previous.displayTitle}',
      if (followers.isNotEmpty) '↪ ${followers.length} 場後續',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      color: color.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kCardRadius),
        side: BorderSide(color: color.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _chainOpen = !_chainOpen),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: color, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Icon(_chainOpen ? Icons.expand_less : Icons.expand_more, color: color),
                ],
              ),
            ),
          ),
          if (_chainOpen) ...[
            if (followsOne && previous == null)
              ListTile(
                dense: true,
                leading: const Icon(Icons.link_off),
                title: const Text('接續的會議已刪除'),
                subtitle: const Text('點這裡重新選擇'),
                onTap: _pickPrevious,
              ),
            if (previous != null)
              ListTile(
                dense: true,
                leading: Icon(Icons.subdirectory_arrow_left, color: color),
                title: Text(previous.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('上一場 · ${formatIsoDate(previous.createdAt)}', style: muted),
                onTap: () => _openMeeting(previous),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(icon: const Icon(Icons.edit_outlined, size: 20), tooltip: '更換接續', onPressed: _pickPrevious),
                    IconButton(
                      icon: Icon(Icons.link_off, size: 20, color: scheme.error),
                      tooltip: '取消接續',
                      onPressed: () => _confirmUnlink(previous),
                    ),
                  ],
                ),
              ),
            for (final follower in followers)
              ListTile(
                dense: true,
                leading: Icon(Icons.subdirectory_arrow_right, color: color),
                title: Text(follower.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('後續 · ${formatIsoDate(follower.createdAt)}', style: muted),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openMeeting(follower),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _openMeeting(Recording recording) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => MeetingDetailScreen(recording: recording, store: widget.store)));
    // Its title, analysis or links may have changed there.
    await _loadAll();
  }

  /// Unlinking only drops the link, never a recording; an analysis that
  /// compared against it goes stale (spec feature-chain-links, decision 8).
  Future<void> _confirmUnlink(Recording previous) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消接續？'),
        content: Text(
          '「${previous.displayTitle}（${formatIsoDate(previous.createdAt)}）」\n\n'
          '只會解除這兩場的關係，不會刪除錄音。這場的「與上次相比」要重新分析後才會更新。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('保留')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取消接續'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _setPrevious(null);
  }

  void _setPrevious(String? id) {
    widget.recording.previousRecordingId = id;
    if (widget.recording.analysis != null) widget.recording.previousChangedSinceAnalysis = true;
    _persist();
  }

  /// Picks the earlier meeting this one follows, or clears it. Changing it
  /// marks an existing analysis stale (spec feature-cross-meeting-memory,
  /// decision 7).
  Future<void> _pickPrevious() async {
    final all = await _store.loadAll();
    if (!mounted) return;
    setState(() => _all = all);
    final current = widget.recording.previousRecordingId;
    final candidates = previousCandidates(widget.recording, all);
    final picked = await showModalBottomSheet<({String? id})>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('接續哪一場會議？'),
              subtitle: Text('只列出比這場早的會議；日期依加入 App 的時間'),
            ),
            if (current != null)
              ListTile(
                leading: const Icon(Icons.link_off),
                title: const Text('取消接續'),
                onTap: () => Navigator.pop(context, (id: null)),
              ),
            if (candidates.isEmpty) const ListTile(title: Text('沒有更早的會議')),
            for (final r in candidates)
              ListTile(
                enabled: r.analysis != null,
                leading: Icon(r.id == current ? Icons.check : Icons.event_note_outlined),
                title: Text(r.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  r.analysis == null ? '${formatIsoDate(r.createdAt)} · 尚未分析' : formatIsoDate(r.createdAt),
                ),
                onTap: () => Navigator.pop(context, (id: r.id)),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked.id == current) return;
    final previous = previousOf(widget.recording, all);
    if (picked.id == null && previous != null) return _confirmUnlink(previous);
    _setPrevious(picked.id);
  }

  Widget _buildNotesSection() {
    final notes = [...widget.recording.notes]
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
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
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
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
          Card(
            child: ListTile(
              leading: _noteIcon(note),
              title: Text(note.kind == UserNoteKind.star ? '重點標記' : note.text ?? ''),
              // The user's words above, the AI's reading below — styled apart
              // so one is never mistaken for the other.
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Align(alignment: Alignment.centerLeft, child: _TimePill(note.timestampMs)),
                  if (contexts[note.id] case final aiContext?)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
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
          ),
      ],
    );
  }

  /// Star in amber, a written note in grey, each on a round base.
  Widget _noteIcon(UserNote note) {
    final star = note.kind == UserNoteKind.star;
    final colors = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: 16,
      backgroundColor: star ? colors.amberSoft : scheme.surfaceContainerHighest,
      foregroundColor: star ? colors.amber : scheme.onSurfaceVariant,
      child: Icon(star ? Icons.star : Icons.notes, size: 18),
    );
  }

  Widget _buildSummary(MeetingAnalysis? analysis) {
    return _analysisGate(analysis, (a) {
      final copyText = summaryCopyText(a);
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('摘要', style: Theme.of(context).textTheme.titleLarge),
                      const Spacer(),
                      RoundIconButton(
                        icon: Icons.copy,
                        tooltip: '複製摘要',
                        onPressed: () => _copy(copyText),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(a.overview),
                        const SizedBox(height: 8),
                        for (final point in a.keyPoints) SelectableText('• $point'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!a.followUp.isEmpty) _buildFollowUpCard(a.followUp),
        ],
      );
    });
  }

  /// "與上次相比", in the summary card's plain style: the whole summary is
  /// AI output already (spec decision 10).
  Widget _buildFollowUpCard(FollowUp followUp) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(text, style: theme.textTheme.titleSmall),
        );
    Widget item({required String label, required String title, String? detail, int? ms}) => ListTile(
          dense: true,
          title: Text.rich(TextSpan(children: [
            TextSpan(text: '$label　', style: TextStyle(color: theme.colorScheme.primary)),
            TextSpan(text: title),
          ])),
          subtitle: detail == null && ms == null
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (detail != null && detail.isNotEmpty) Text(detail, style: muted),
                    if (ms != null)
                      Padding(padding: const EdgeInsets.only(top: 4), child: _TimePill(ms)),
                  ],
                ),
          onTap: ms == null ? null : () => _seekAndPlay(Duration(milliseconds: ms)),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('與上次相比', style: theme.textTheme.titleLarge),
            ),
            if (followUp.todoProgress.isNotEmpty) ...[
              heading('上次的待辦'),
              for (final p in followUp.todoProgress)
                item(label: p.status.label, title: p.task, detail: p.note, ms: p.sourceTimestampMs),
            ],
            if (followUp.decisionChanges.isNotEmpty) ...[
              heading('決議的變化'),
              for (final d in followUp.decisionChanges)
                item(
                  label: d.change.label,
                  title: d.current,
                  detail: '上次：${d.previousDecision}',
                  ms: d.sourceTimestampMs,
                ),
            ],
            if (followUp.newTopics.isNotEmpty) ...[
              heading('新的主題'),
              for (final topic in followUp.newTopics)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                  child: Text('• $topic'),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTodosTab(MeetingAnalysis? analysis) {
    return _analysisGate(analysis, (a) {
      if (a.todos.isEmpty) return const Center(child: Text('沒有待辦事項'));
      debugPrint(
        '[Detail] todo timestamps: '
        '${a.todos.map((t) => t.sourceTimestampMs).toList()}',
      );
      final muted = Theme.of(context).colorScheme.onSurfaceVariant;
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: a.todos.length,
        itemBuilder: (context, index) {
          final todo = a.todos[index];
          final meta = [
            if (todo.owner != null) todo.owner!,
            if (todo.dueDate != null) '期限 ${todo.dueDate}',
          ].join(' · ');
          // The task gets the whole first line; the actions sit below it
          // so they don't squeeze it (spec feature-todo-layout, option A).
          return Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: todo.sourceTimestampMs != null
                  ? () => _seekAndPlay(Duration(milliseconds: todo.sourceTimestampMs!))
                  : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: todo.done,
                      onChanged: (value) {
                        todo.done = value ?? false;
                        _persist();
                      },
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 10, right: 8),
                            child: Text(
                              todo.task,
                              style: TextStyle(
                                fontSize: 18,
                                height: 1.4,
                                fontWeight: FontWeight.w500,
                                decoration: todo.done ? TextDecoration.lineThrough : null,
                                color: todo.done ? muted : null,
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: Text(meta, style: TextStyle(fontSize: 13, color: muted)),
                              ),
                              if (todo.sourceTimestampMs != null) _TimePill(todo.sourceTimestampMs!),
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 20),
                                tooltip: '編輯待辦',
                                onPressed: () => _editTodoTask(todo),
                              ),
                              IconButton(
                                icon: Icon(Icons.delete_outline, size: 20, color: Theme.of(context).colorScheme.error),
                                tooltip: '刪除待辦',
                                onPressed: () => _confirmDeleteTodo(a, todo),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    });
  }

  /// A deleted todo can't be brought back, so ask first, naming the todo.
  Future<void> _confirmDeleteTodo(MeetingAnalysis analysis, Todo todo) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('刪除這筆待辦？'),
        content: Text('「${todo.task}」\n刪除後無法復原。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    analysis.todos.remove(todo);
    _persist();
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
            children: [
              // Long press isn't discoverable on its own.
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    '點句子跳轉播放，長按可修改',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline),
                  ),
                ),
              ),
              RoundIconButton(
                icon: Icons.copy,
                tooltip: '複製全部逐字稿',
                onPressed: segments.isEmpty ? null : () => _copy(_transcriptText),
              ),
              RoundIconButton(
                icon: Icons.ios_share,
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
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                child: ListTile(
                  dense: true,
                  leading: _TimePill(segment.startMs),
                  title: Text(segment.text, style: Theme.of(context).textTheme.bodyMedium),
                  trailing: notes.isEmpty
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final note in notes)
                              Icon(
                                note.kind == UserNoteKind.star ? Icons.star : Icons.notes,
                                size: 18,
                                color: AppColors.of(context).amber,
                              ),
                          ],
                        ),
                  onTap: () => _seekAndPlay(Duration(milliseconds: segment.startMs)),
                  onLongPress: () => _editSegment(segment),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMinutesTab(MeetingAnalysis? analysis) {
    return _analysisGate(analysis, (a) {
      debugPrint(
        '[Detail] agenda item timestamps: '
        '${a.agendaItems.map((i) => i.sourceTimestampMs).toList()}',
      );
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Text(a.title, style: Theme.of(context).textTheme.titleLarge),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
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
          ),
          const SizedBox(height: 16),
          for (final item in a.agendaItems)
            Card(
              child: ListTile(
                title: Text(item.topic),
                subtitle: Text(
                  [
                    item.discussion,
                    for (final decision in item.decisions) '決議: $decision',
                  ].where((s) => s.isNotEmpty).join('\n'),
                ),
                isThreeLine: true,
                trailing: item.sourceTimestampMs != null
                    ? _TimePill(item.sourceTimestampMs!)
                    : null,
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

/// The four tabs as a bottom bar, kept in step with the swipeable pages.
class _TabNavigationBar extends StatelessWidget {
  const _TabNavigationBar();

  @override
  Widget build(BuildContext context) {
    final controller = DefaultTabController.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => NavigationBar(
        selectedIndex: controller.index,
        onDestinationSelected: controller.animateTo,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.summarize_outlined),
            selectedIcon: Icon(Icons.summarize),
            label: '摘要',
          ),
          NavigationDestination(icon: Icon(Icons.checklist), label: '待辦'),
          NavigationDestination(
            icon: Icon(Icons.subtitles_outlined),
            selectedIcon: Icon(Icons.subtitles),
            label: '逐字稿',
          ),
          NavigationDestination(
            icon: Icon(Icons.article_outlined),
            selectedIcon: Icon(Icons.article),
            label: '紀錄',
          ),
        ],
      ),
    );
  }
}

/// A position in the recording, as a cyan pill; tapping its row seeks there.
class _TimePill extends StatelessWidget {
  const _TimePill(this.ms);

  final int ms;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.of(context).accentSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        formatMs(ms),
        style: TextStyle(
          color: scheme.primary,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

enum _MoreAction { previous, export, reanalyze, retranscribe, delete }

enum _LearnChoice { dismiss, learn, learnAndApply }

/// Owns its text controller, so the field outlives the closing animation.
class _LearnDialog extends StatefulWidget {
  const _LearnDialog({required this.detected, required this.countOthers});

  final Replacement detected;

  /// How many more times a misspelling appears in the recording.
  final int Function(String misspelling) countOthers;

  @override
  State<_LearnDialog> createState() => _LearnDialogState();
}

class _LearnDialogState extends State<_LearnDialog> {
  late final _term = TextEditingController(text: widget.detected.after);

  @override
  void dispose() {
    _term.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expanded = expandToTerm(widget.detected, _term.text.trim());
    final others = widget.countOthers(expanded.before);
    void answer(_LearnChoice choice) =>
        Navigator.pop(context, (choice: choice, expanded: expanded));
    return AlertDialog(
      title: const Text('記住這個寫法？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _term,
            decoration: const InputDecoration(labelText: '正確寫法（可補成完整的詞）'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Text('會把「${expanded.before}」記成「${expanded.after}」'),
          if (others > 0) ...[
            const SizedBox(height: 4),
            Text('這場錄音的其他地方還有 $others 處「${expanded.before}」'),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => answer(_LearnChoice.dismiss), child: const Text('不用')),
        TextButton(onPressed: () => answer(_LearnChoice.learn), child: const Text('只加入詞庫')),
        if (others > 0)
          TextButton(
            onPressed: () => answer(_LearnChoice.learnAndApply),
            child: Text('加入並修正 $others 處'),
          ),
      ],
    );
  }
}
