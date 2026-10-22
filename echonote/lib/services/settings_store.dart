import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// App preferences in `Documents/settings.json`. Small and non-critical: a
/// missing or unreadable file means defaults, and it's then overwritten.
class SettingsStore {
  SettingsStore({Future<Directory> Function()? documentsDir})
    : _documentsDir = documentsDir ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDir;

  static const _livePreviewKey = 'live_preview';

  Future<File> _file() async => File('${(await _documentsDir()).path}/settings.json');

  Future<Map<String, dynamic>> _read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return {};
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// Whether live text shows while recording. Off unless turned on: the
  /// preview is only a rough draft (spec feature-recording-indicator).
  Future<bool> livePreview() async {
    final value = (await _read())[_livePreviewKey];
    return value is bool ? value : false;
  }

  /// Keeps any other settings already in the file.
  Future<void> setLivePreview(bool value) async {
    final settings = await _read()
      ..[_livePreviewKey] = value;
    await (await _file()).writeAsString(jsonEncode(settings));
  }
}
