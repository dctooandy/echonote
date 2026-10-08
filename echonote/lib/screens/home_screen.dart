import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/recording.dart';
import '../services/recording_store.dart';
import '../widgets/confirm_delete_dialog.dart';
import 'import_screen.dart';
import 'live_record_screen.dart';
import 'meeting_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _store = RecordingStore();
  late Future<List<Recording>> _recordingsFuture;

  @override
  void initState() {
    super.initState();
    _recordingsFuture = _store.loadAll();
  }

  void _reload() {
    setState(() {
      _recordingsFuture = _store.loadAll();
    });
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
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const LiveRecordScreen()),
      );
    } finally {
      _openingLive = false;
    }
    _reload();
  }

  String _statusLabel(Recording recording) {
    if (!recording.isTranscribed) return '未轉錄';
    if (recording.analysis == null) return '待分析';
    return '已完成';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('echonote')),
      floatingActionButton: _ExpandableFab(
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
            return const Center(child: Text('還沒有任何錄音，點右下角「+」匯入或即時錄音'));
          }
          return ListView.builder(
            itemCount: recordings.length,
            itemBuilder: (context, index) {
              final recording = recordings[index];
              final hasAnalysis = recording.analysis != null;
              return Dismissible(
                key: ValueKey(recording.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Colors.red,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: const Icon(Icons.delete, color: Colors.white),
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
                child: ListTile(
                  leading: Icon(
                    !recording.isTranscribed
                        ? Icons.pending_outlined
                        : hasAnalysis
                        ? Icons.check_circle
                        : Icons.description_outlined,
                  ),
                  title: Text(recording.displayTitle),
                  subtitle: Text(
                    '${recording.createdAt.toLocal()}'.split('.').first,
                  ),
                  trailing: Text(_statusLabel(recording)),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => MeetingDetailScreen(recording: recording),
                      ),
                    );
                    _reload();
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Decision #9: the "+" opens two choices — import a file or record live.
class _ExpandableFab extends StatefulWidget {
  const _ExpandableFab({required this.onImport, required this.onRecord});

  final VoidCallback onImport;
  final VoidCallback onRecord;

  @override
  State<_ExpandableFab> createState() => _ExpandableFabState();
}

class _ExpandableFabState extends State<_ExpandableFab> {
  bool _open = false;

  void _choose(VoidCallback action) {
    setState(() => _open = false);
    action();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_open) ...[
          FloatingActionButton.extended(
            heroTag: 'fab-record',
            onPressed: () => _choose(widget.onRecord),
            icon: const Icon(Icons.mic),
            label: const Text('即時錄音'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'fab-import',
            onPressed: () => _choose(widget.onImport),
            icon: const Icon(Icons.upload_file),
            label: const Text('匯入錄音檔'),
          ),
          const SizedBox(height: 16),
        ],
        FloatingActionButton(
          heroTag: 'fab-main',
          onPressed: () => setState(() => _open = !_open),
          tooltip: _open ? '關閉' : '新增錄音',
          child: Icon(_open ? Icons.close : Icons.add),
        ),
      ],
    );
  }
}
