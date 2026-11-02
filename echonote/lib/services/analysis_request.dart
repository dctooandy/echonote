import '../models/recording.dart';
import 'meeting_chain.dart';

// Builds the analyzeMeeting request. Plain Dart (no Flutter plugins), so the
// eval-set export tool sends exactly what the app sends (spec
// feature-analysis-eval-set, decision 2).

/// The analyzeMeeting request for [segments], plus what reading the answer
/// needs: the note id behind each `note_index`, and the latest previous
/// meeting's todos as sent (for `previous_todo_index`). [previous] is the
/// chain of earlier meetings, oldest first (see [previousChain]). [myName]
/// is the user's own name, given only for a meeting they took part in
/// (spec feature-my-name).
({Map<String, dynamic> request, List<String> noteIds, List<String> previousTodos}) buildAnalysisRequest(
  List<TranscriptSegment> segments, {
  List<String> glossary = const [],
  List<UserNote> notes = const [],
  List<Recording> previous = const [],
  String? myName,
}) {
  final highlights = buildHighlights(notes, segments);
  final previousPayload = previous.map(toPreviousMeetingPayload).toList();
  return (
    request: {
      'segments': segments.map((s) => s.toJson()).toList(),
      if (glossary.isNotEmpty) 'glossary': glossary,
      if (highlights.payload.isNotEmpty) 'highlights': highlights.payload,
      if (previousPayload.isNotEmpty) 'previous_meetings': previousPayload,
      if (myName != null && myName.trim().isNotEmpty) 'my_name': myName.trim(),
    },
    noteIds: highlights.noteIds,
    previousTodos: previousPayload.isEmpty
        ? const []
        : [for (final t in previousPayload.last['todos'] as List) (t as Map)['task'] as String],
  );
}

/// The segment a note at [timestampMs] falls in: the last one starting at
/// or before it, or the first one when the note is earlier than all of
/// them. Looked up at analysis time because re-transcription replaces the
/// segments while notes keep only their timestamp. [segments] must be
/// non-empty and in time order.
int segmentIndexFor(int timestampMs, List<TranscriptSegment> segments) {
  var index = 0;
  for (var i = 0; i < segments.length && segments[i].startMs <= timestampMs; i++) {
    index = i;
  }
  return index;
}

/// The request's `highlights`, plus the note id behind each `note_index`.
/// Notes go in time order so the model reads them as the meeting unfolds.
({List<Map<String, dynamic>> payload, List<String> noteIds}) buildHighlights(
  List<UserNote> notes,
  List<TranscriptSegment> segments,
) {
  if (segments.isEmpty) return (payload: [], noteIds: []);
  final sorted = [...notes]..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
  return (
    payload: [
      for (var i = 0; i < sorted.length; i++)
        {
          'note_index': i,
          'segment_index': segmentIndexFor(sorted[i].timestampMs, segments),
          'text': sorted[i].kind == UserNoteKind.star ? null : sorted[i].text,
        },
    ],
    noteIds: [for (final note in sorted) note.id],
  );
}
