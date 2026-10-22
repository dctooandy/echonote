import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/recording.dart';
import '../services/audio_duration_probe.dart';
import '../services/app_settings.dart';
import '../services/recording_store.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import '../widgets/confirm_delete_dialog.dart';
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
          return ListView.builder(
            // Room under the last card for the record buttons.
            padding: const EdgeInsets.only(top: 4, bottom: 150),
            itemCount: recordings.length,
            itemBuilder: (context, index) {
              final recording = recordings[index];
              final status = _Status.of(context, recording);
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
                    if (context.mounted) {
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
                    leading: CircleAvatar(
                      radius: 19,
                      backgroundColor: status.background,
                      foregroundColor: status.color,
                      child: Icon(status.icon, size: 20),
                    ),
                    title: Text(
                      recording.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      formatListDate(recording.createdAt.toLocal(), DateTime.now()),
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
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
            },
          );
        },
      ),
    );
  }
}

/// A recording's state as the list shows it: grey to do, amber halfway,
/// green done (spec feature-dark-theme).
class _Status {
  const _Status(this.label, this.icon, this.color, this.background);

  factory _Status.of(BuildContext context, Recording recording) {
    final scheme = Theme.of(context).colorScheme;
    final colors = AppColors.of(context);
    if (!recording.isTranscribed) {
      return _Status(
        '未轉錄',
        Icons.pending_outlined,
        scheme.onSurfaceVariant,
        scheme.surfaceContainerHighest,
      );
    }
    if (recording.analysis == null) {
      return _Status('待分析', Icons.description_outlined, colors.amber, colors.amberSoft);
    }
    return _Status('已完成', Icons.check_circle, colors.green, colors.greenSoft);
  }

  final String label;
  final IconData icon;
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
