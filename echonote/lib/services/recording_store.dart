import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/recording.dart';

class RecordingStore {
  Future<Directory> _historyDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final historyDir = Directory('${dir.path}/history');
    if (!await historyDir.exists()) await historyDir.create(recursive: true);
    return historyDir;
  }

  Future<Directory> recordingsDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final recDir = Directory('${dir.path}/recordings');
    if (!await recDir.exists()) await recDir.create(recursive: true);
    return recDir;
  }

  Future<void> save(Recording recording) async {
    final dir = await _historyDir();
    final file = File('${dir.path}/${recording.id}.json');
    await file.writeAsString(jsonEncode(recording.toJson()));
  }

  /// Resolves [recording]'s audio file to an absolute path under the
  /// *current* app container. Never store the absolute path itself — iOS
  /// relocates the sandbox container (a new UUID) across app reinstalls and
  /// sometimes across ordinary relaunches, so a path captured at import time
  /// can point at a container that no longer exists.
  Future<String> resolveAudioPath(Recording recording) async {
    final dir = await recordingsDir();
    return '${dir.path}/${recording.audioFileName}';
  }

  Future<List<Recording>> loadAll() async {
    final dir = await _historyDir();
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
    final recordings = <Recording>[];
    for (final file in files) {
      try {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        recordings.add(Recording.fromJson(json));
      } catch (_) {
        // Skip unreadable/corrupt entries rather than crashing the list.
      }
    }
    recordings.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return recordings;
  }
}
