import '../models/recording.dart';

/// Meetings [current] may follow: created before it, newest first. Earlier
/// only, so following can never loop. Unanalyzed ones are included; the
/// picker shows them disabled (spec feature-cross-meeting-memory, decision 2).
List<Recording> previousCandidates(Recording current, List<Recording> all) =>
    all.where((r) => r.id != current.id && r.createdAt.isBefore(current.createdAt)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

/// The meeting [current] follows, or null when it follows none or that one
/// was deleted.
Recording? previousOf(Recording current, List<Recording> all) {
  final id = current.previousRecordingId;
  if (id == null) return null;
  for (final r in all) {
    if (r.id == id) return r;
  }
  return null;
}
