import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/recording.dart';
import '../services/recording_store.dart';
import 'import_screen.dart';
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

  String _statusLabel(Recording recording) {
    if (recording.analysis == null) return '待分析';
    return '已完成';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('echonote')),
      floatingActionButton: FloatingActionButton(
        onPressed: _importRecording,
        tooltip: '匯入錄音',
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<List<Recording>>(
        future: _recordingsFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final recordings = snapshot.data!;
          if (recordings.isEmpty) {
            return const Center(child: Text('還沒有任何錄音，點右下角「+」匯入'));
          }
          return ListView.builder(
            itemCount: recordings.length,
            itemBuilder: (context, index) {
              final recording = recordings[index];
              final hasAnalysis = recording.analysis != null;
              return ListTile(
                leading: Icon(hasAnalysis ? Icons.check_circle : Icons.description_outlined),
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
              );
            },
          );
        },
      ),
    );
  }
}
