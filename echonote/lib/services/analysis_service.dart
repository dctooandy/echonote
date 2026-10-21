import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';

import '../models/recording.dart';

class AnalysisService {
  /// False when Firebase didn't initialize (not configured on Android yet).
  static bool available = false;

  /// [glossary] is sent whole (the store caps it at 200 terms), not trimmed
  /// to what fits in the whisper prompt: Claude can still fix the terms
  /// whisper had no room for.
  Future<MeetingAnalysis> analyze(
    List<TranscriptSegment> segments, {
    List<String> glossary = const [],
    List<UserNote> notes = const [],
  }) async {
    final highlights = buildHighlights(notes, segments);
    final callable = FirebaseFunctions.instance.httpsCallable('analyzeMeeting');
    final result = await callable.call<Map<String, dynamic>>({
      'segments': segments.map((s) => s.toJson()).toList(),
      if (glossary.isNotEmpty) 'glossary': glossary,
      if (highlights.payload.isNotEmpty) 'highlights': highlights.payload,
    });
    // The plugin returns nested Map<Object?, Object?> from the platform channel;
    // round-tripping through JSON normalizes it to plain Map<String, dynamic>.
    final data = jsonDecode(jsonEncode(result.data)) as Map<String, dynamic>;
    _resolveSegmentIndices(data, segments);
    data['highlight_contexts'] = resolveHighlightContexts(
      data['highlight_contexts'],
      highlights.noteIds,
    );
    return MeetingAnalysis.fromJson(data);
  }

  /// Claude is asked to reference transcript lines by their small sequential
  /// index (`source_segment_index`, e.g. 0, 1, 2...) rather than by copying
  /// an arbitrary large millisecond value verbatim — on long transcripts
  /// (1000+ segments spanning tens of minutes), asking it to reproduce an
  /// exact large number reliably degrades and it drifts toward small/near-
  /// zero values. Resolving the index to a real timestamp is a deterministic
  /// lookup, so it belongs in code, not in the model's output.
  void _resolveSegmentIndices(Map<String, dynamic> data, List<TranscriptSegment> segments) {
    int? msFor(dynamic index) {
      if (index is! int || index < 0 || index >= segments.length) return null;
      return segments[index].startMs;
    }

    for (final todo in (data['todos'] as List<dynamic>? ?? [])) {
      final map = todo as Map<String, dynamic>;
      map['source_timestamp_ms'] = msFor(map['source_segment_index']);
    }
    final minutes = data['structured_minutes'] as Map<String, dynamic>? ?? {};
    for (final item in (minutes['agenda_items'] as List<dynamic>? ?? [])) {
      final map = item as Map<String, dynamic>;
      map['source_timestamp_ms'] = msFor(map['source_segment_index']);
    }
  }
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

/// Maps the model's `[{note_index, context}]` back to `{noteId: context}`.
/// Entries with an unknown index are dropped; a note the model skipped
/// simply has no context.
Map<String, String> resolveHighlightContexts(dynamic raw, List<String> noteIds) {
  final contexts = <String, String>{};
  for (final entry in (raw is List ? raw : const [])) {
    if (entry is! Map) continue;
    final index = entry['note_index'];
    final context = entry['context'];
    if (index is! int || index < 0 || index >= noteIds.length || context is! String) continue;
    contexts[noteIds[index]] = context;
  }
  return contexts;
}
