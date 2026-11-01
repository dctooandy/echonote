import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/recording.dart';
import '../services/audio_duration_probe.dart';
import '../services/meeting_chain.dart';
import '../services/app_settings.dart';
import '../services/recording_store.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import '../widgets/confirm_delete_dialog.dart';
import '../widgets/marquee.dart';
import '../widgets/round_icon_button.dart';
import 'glossary_screen.dart';
import 'import_screen.dart';
import 'live_record_screen.dart';
import 'meeting_detail_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.durationProbe});

  /// Test seam; by default reads the audio files with just_audio.
  final AudioDurationProbe? durationProbe;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _store = RecordingStore();
  late final _probe = widget.durationProbe ?? AudioDurationProbe();
  late Future<List<Recording>> _recordingsFuture;

  /// Bumped on every load, so a fill-in pass over an older list stops.
  int _loadCount = 0;

  @override
  void initState() {
    super.initState();
    _recordingsFuture = _load();
  }

  void _reload() {
    setState(() {
      _recordingsFuture = _load();
    });
  }

  Future<List<Recording>> _load() async {
    final recordings = await _store.loadAll();
    unawaited(_fillInDurations(recordings, ++_loadCount));
    return recordings;
  }

  /// Entries saved before lengths were recorded get theirs from the audio
  /// file, one at a time, each row updating as it's read. An unreadable
  /// file is simply tried again next time (spec feature-recording-duration).
  Future<void> _fillInDurations(List<Recording> recordings, int load) async {
    for (final recording in recordings) {
      if (!mounted || load != _loadCount) return;
      if (recording.durationMs != null) continue;
      final ms = await _probe.durationMs(await _store.resolveAudioPath(recording));
      if (ms == null || !mounted || load != _loadCount) continue;
      await _store.saveDuration(recording.id, ms);
      if (mounted) setState(() => recording.durationMs = ms);
    }
  }

  Future<void> _importRecording() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['m4a', 'mp3', 'wav'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    final audioName = result!.files.single.name;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImportScreen(audioPath: path, audioName: audioName),
      ),
    );
    _reload();
  }

  bool _openingLive = false;

  Future<void> _startLiveRecording() async {
    // A double tap would open a second screen whose start fails with
    // alreadyRunning; ignore taps while one is open.
    if (_openingLive) return;
    _openingLive = true;
    try {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LiveRecordScreen()));
    } finally {
      _openingLive = false;
    }
    _reload();
  }

  /// Status chip, with the length under it once it's known (specs
  /// feature-recording-duration, feature-dark-theme).
  Widget _trailing(BuildContext context, Recording recording) {
    final status = _Status.of(context, recording);
    final ms = recording.durationMs;
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
          decoration: BoxDecoration(
            color: status.background,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            status.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: status.color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (ms != null) ...[
          const SizedBox(height: 4),
          Text(
            formatLength(ms),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final leftHanded = AppSettingsScope.of(context).handedness == Handedness.left;
    return Scaffold(
      appBar: AppBar(
        title: const Text('echonote'),
        actions: [
          RoundIconButton(
            icon: Icons.menu_book_outlined,
            tooltip: '詞庫',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const GlossaryScreen())),
          ),
          RoundIconButton(
            icon: Icons.settings_outlined,
            tooltip: '設定',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          const SizedBox(width: 9),
        ],
      ),
      // On the thumb's side (spec feature-dark-theme).
      floatingActionButtonLocation: leftHanded
          ? FloatingActionButtonLocation.startFloat
          : FloatingActionButtonLocation.endFloat,
      floatingActionButton: _RecordButtons(
        onImport: _importRecording,
        onRecord: _startLiveRecording,
      ),
      body: FutureBuilder<List<Recording>>(
        future: _recordingsFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final recordings = snapshot.data!;
          if (recordings.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '還沒有任何錄音，點${leftHanded ? '左' : '右'}下角的紅色按鈕開始錄音，或上方的按鈕匯入錄音檔',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final view = AppSettingsScope.of(context).homeView;
          return Column(
            children: [
              _ViewTabs(
                selected: view,
                // On the thumb's side, like the record buttons.
                alignment: leftHanded ? Alignment.centerLeft : Alignment.centerRight,
                onSelected: AppSettingsScope.of(context).setHomeView,
              ),
              Expanded(
                child: view == HomeView.single
                    ? _buildSingleList(recordings)
                    : _buildSeriesList(recordings),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Room under the last card for the record buttons.
  static const _listPadding = EdgeInsets.only(top: 4, bottom: 150);

  /// One meeting at a time, newest first, each saying what it follows
  /// (spec feature-chain-links, decision 4).
  Widget _buildSingleList(List<Recording> recordings) {
    // The hint takes its series' color, so a series reads as one here too
    // (decision 14).
    final colorOf = {
      for (final s in seriesOf(recordings))
        for (final r in s.recordings) r.id: s.colorIndex,
    };
    // Grouped by day under a heading, so each card shows only its time
    // (decision 16).
    final now = DateTime.now();
    final items = <Object>[];
    String? day;
    for (final r in recordings) {
      final heading = formatDayHeading(r.createdAt.toLocal(), now);
      if (heading != day) items.add(day = heading);
      items.add(r);
    }
    return ListView.builder(
      padding: _listPadding,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        if (item is String) return _DayHeading(item);
        final recording = item as Recording;
        final color = colorOf[recording.id];
        return _row(
          recording,
          recordings,
          hint: chainHint(recording, recordings),
          hintColor: color == null ? null : seriesColor(context, color),
        );
      },
    );
  }

  /// Only linked meetings, one colored frame per series (spec
  /// feature-chain-links, decision 5).
  Widget _buildSeriesList(List<Recording> recordings) {
    final series = seriesOf(recordings);
    final linked = series.fold(0, (n, s) => n + s.recordings.length);
    final alone = recordings.length - linked;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    if (series.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('還沒有接續的會議。在會議的「⋯」選單選「接續上一場」就能串起來', textAlign: TextAlign.center, style: TextStyle(color: muted)),
        ),
      );
    }
    return ListView(
      padding: _listPadding,
      children: [
        for (final s in series) _seriesFrame(s, recordings),
        if (alone > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('另有 $alone 場沒有接續，在「全部」裡', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: muted)),
          ),
      ],
    );
  }

  Widget _seriesFrame(MeetingSeries series, List<Recording> recordings) {
    final color = seriesColor(context, series.colorIndex);
    return Container(
      key: ValueKey('series-${series.recordings.last.id}'),
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(kCardRadius + 4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Long press to name the series (decision 17).
          InkWell(
            onLongPress: () => _renameSeries(series),
            child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Row(
              children: [
                Icon(Icons.circle, size: 10, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    series.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '${series.recordings.length} 場 · 最近 ${formatMonthDay(series.latest)}',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          ),
          for (var i = 0; i < series.recordings.length; i++)
            _row(series.recordings[i], recordings, hint: seriesRowHint(series, i), hintColor: color, withDate: true),
        ],
      ),
    );
  }

  /// The series' name is kept on its first meeting; empty goes back to
  /// the latest meeting's name (decision 17).
  Future<void> _renameSeries(MeetingSeries series) async {
    final controller = TextEditingController(text: series.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('系列名稱'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(helperText: '清空就用最近一場的名稱'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('儲存')),
        ],
      ),
    );
    if (name == null) return;
    final trimmed = name.trim();
    series.first.seriesName = trimmed.isEmpty ? null : trimmed;
    await _store.save(series.first);
    _reload();
  }

  /// One meeting's card: its time on the left (with the date too inside a
  /// series frame, which isn't grouped by day), name and link hint in the
  /// middle, state and length on the right (decision 16).
  Widget _row(
    Recording recording,
    List<Recording> recordings, {
    ChainHint hint = const ChainHint(),
    Color? hintColor,
    bool withDate = false,
  }) {
    final at = recording.createdAt.toLocal();
    final theme = Theme.of(context);
    const tabular = [FontFeature.tabularFigures()];
    return Dismissible(
      key: ValueKey(recording.id),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.error,
          borderRadius: BorderRadius.circular(kCardRadius),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Icon(Icons.delete, color: Theme.of(context).colorScheme.onError),
      ),
      confirmDismiss: (_) => confirmDeleteRecording(context, recording),
      onDismissed: (_) async {
        // Out of the list right away: a dismissed Dismissible must
        // leave the tree before the next frame.
        recordings.remove(recording);
        try {
          await _store.delete(recording);
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('刪除失敗: $e')));
          }
        }
        _reload();
      },
      child: Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          // Same height with or without a hint line, so the status and
          // length on the right always fit.
          minTileHeight: 64,
          minLeadingWidth: 46,
          leading: SizedBox(
            width: 46,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              // One line each, shrunk rather than wrapped under large text.
              children: [
                if (withDate)
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(formatMonthDay(at), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontFeatures: tabular)),
                  ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(formatClock(at), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, fontFeatures: tabular)),
                ),
              ],
            ),
          ),
          horizontalTitleGap: 8,
          title: Text(
            recording.displayTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: hint.isEmpty ? null : _HintLine(hint: hint, color: hintColor ?? theme.colorScheme.primary),
          trailing: _trailing(context, recording),
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MeetingDetailScreen(recording: recording),
              ),
            );
            _reload();
          },
        ),
      ),
    );
  }
}

/// 全部 and 系列 as two wide tabs over most of the row, on the thumb's side,
/// the current one underlined (spec feature-chain-links, decision 14):
/// each is a big target without a taller row.
class _ViewTabs extends StatelessWidget {
  const _ViewTabs({required this.selected, required this.alignment, required this.onSelected});

  final HomeView selected;
  final Alignment alignment;
  final ValueChanged<HomeView> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget tab(HomeView view, String label) {
      final on = view == selected;
      return Expanded(
        child: InkWell(
          onTap: on ? null : () => onSelected(view),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: on ? scheme.primary : Colors.transparent, width: 3)),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                color: on ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Align(
        alignment: alignment,
        child: FractionallySizedBox(
          widthFactor: 0.62,
          child: Container(
            height: 44,
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.outlineVariant))),
            child: Row(children: [tab(HomeView.single, '全部'), tab(HomeView.series, '系列')]),
          ),
        ),
      ),
    );
  }
}

/// A day's heading over its cards in 全部 (decision 16).
class _DayHeading extends StatelessWidget {
  const _DayHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
    child: Text(
      text,
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

/// What a meeting links to, in its series' color, with arrow icons rather
/// than ↩/↪ (iOS draws those as emoji). Scrolls when too long for one line
/// (decisions 13 to 15).
class _HintLine extends StatelessWidget {
  const _HintLine({required this.hint, required this.color});

  final ChainHint hint;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final linked = TextStyle(color: color, fontWeight: FontWeight.w600);
    Widget part(IconData icon, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 2),
        Text(text, style: linked),
      ],
    );
    return Marquee(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hint.follows != null) part(Icons.subdirectory_arrow_left, '接續 ${hint.follows}'),
          if (hint.follows != null && hint.followers > 0) Text(' · ', style: linked),
          if (hint.followers > 0) part(Icons.subdirectory_arrow_right, '${hint.followers} 場後續'),
        ],
      ),
    );
  }
}

/// A recording's state as the list shows it: grey to do, amber halfway,
/// green done (spec feature-dark-theme).
class _Status {
  const _Status(this.label, this.color, this.background);

  factory _Status.of(BuildContext context, Recording recording) {
    final scheme = Theme.of(context).colorScheme;
    final colors = AppColors.of(context);
    if (!recording.isTranscribed) {
      return _Status(
        '未轉錄',
        scheme.onSurfaceVariant,
        scheme.surfaceContainerHighest,
      );
    }
    if (recording.analysis == null) {
      return _Status('待分析', colors.amber, colors.amberSoft);
    }
    return _Status('已完成', colors.green, colors.greenSoft);
  }

  final String label;
  final Color color;
  final Color background;
}

/// A big red record button that starts recording in one tap, with a
/// labelled import pill above it (spec feature-dark-theme; replaces the "+" menu
/// of decision #9).
class _RecordButtons extends StatelessWidget {
  const _RecordButtons({required this.onImport, required this.onRecord});

  final VoidCallback onImport;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // A labelled cyan pill: easy to spot, still second to record (desk-mode
        // device feedback).
        Tooltip(
          message: '匯入錄音檔',
          child: OutlinedButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.upload_file, size: 20),
            label: const Text('匯入'),
            style: OutlinedButton.styleFrom(
              backgroundColor: scheme.surfaceContainer,
              foregroundColor: scheme.primary,
              side: BorderSide(color: scheme.primary, width: 1.5),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ),
        ),
        const SizedBox(height: 14),
        // The soft ring marks it as the record button.
        DecoratedBox(
          decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.of(context).redSoft),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: SizedBox.square(
              dimension: 72,
              child: FloatingActionButton(
                heroTag: 'fab-record',
                onPressed: onRecord,
                tooltip: '開始錄音',
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
                child: const Icon(Icons.mic, size: 34),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
