import 'dart:io';

var _nextTemp = 0;

/// Writes [contents] to [file] without risking what's already there: a
/// failure part way leaves the old file whole, because the new one only
/// replaces it once fully written (spec fix-save-failure-notice, decision 2).
/// Each call has its own temp file, so overlapping writes can't trip on
/// each other.
Future<void> writeStringAtomically(File file, String contents) async {
  final temp = File('${file.path}.${_nextTemp++}.tmp');
  try {
    await temp.writeAsString(contents, flush: true);
    await temp.rename(file.path);
  } catch (_) {
    if (await temp.exists()) await temp.delete();
    rethrow;
  }
}
