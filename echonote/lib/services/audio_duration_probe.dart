import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Reads how long an audio file is (m4a, mp3, wav — whatever import
/// accepts), for entries saved without a length (spec
/// feature-recording-duration).
class AudioDurationProbe {
  /// Null when the file is missing or can't be read; never throws.
  Future<int?> durationMs(String path) async {
    if (!await File(path).exists()) return null;
    final player = AudioPlayer();
    try {
      // Only loads the file; nothing plays, so other audio isn't interrupted.
      final duration = await player.setFilePath(path).timeout(const Duration(seconds: 10));
      return duration?.inMilliseconds;
    } catch (e) {
      debugPrint('[AudioDurationProbe] $path: $e');
      return null;
    } finally {
      // An unloaded player's calls may never complete; don't wait on it.
      player.dispose().ignore();
    }
  }
}
