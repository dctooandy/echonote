import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';

import '../models/recording.dart';
import 'analysis_request.dart';

export 'analysis_request.dart';

class AnalysisService {
  /// False when Firebase didn't initialize (not configured on Android yet).
  static bool available = false;

  /// [glossary] is sent whole (the store caps it at 200 terms), not trimmed
  /// to what fits in the whisper prompt: Claude can still fix the terms
  /// whisper had no room for.
  ///
  /// [previous] is the chain of earlier meetings this one follows, oldest
  /// first (see [previousChain]); only their conclusions are sent.
  Future<MeetingAnalysis> analyze(
    List<TranscriptSegment> segments, {
    List<String> glossary = const [],
    List<UserNote> notes = const [],
    List<Recording> previous = const [],
  }) async {
    final built = buildAnalysisRequest(segments, glossary: glossary, notes: notes, previous: previous);
    final callable = FirebaseFunctions.instance.httpsCallable('analyzeMeeting');
    final result = await callable.call<Map<String, dynamic>>(built.request);
    // The plugin returns nested Map<Object?, Object?> from the platform channel;
    // round-tripping through JSON normalizes it to plain Map<String, dynamic>.
    final data = jsonDecode(jsonEncode(result.data)) as Map<String, dynamic>;
    _resolveSegmentIndices(data, segments);
    data['highlight_contexts'] = resolveHighlightContexts(
      data['highlight_contexts'],
      built.noteIds,
    );
    data['follow_up'] = resolveFollowUp(
      data['follow_up'],
      segments,
      built.previousTodos,
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

/// Turns the model's `follow_up` into the stored form: segment indices
/// become timestamps (out of range → null, like todos), and each
/// `previous_todo_index` becomes the todo's text from [previousTodos] (the
/// latest previous meeting's todos as sent). Entries with an unknown index
/// are dropped, as are repeats; "not mentioned" ones go last (spec
/// decision 9).
Map<String, dynamic> resolveFollowUp(
  dynamic raw,
  List<TranscriptSegment> segments,
  List<String> previousTodos,
) {
  final map = raw is Map ? raw : const {};
  int? msFor(dynamic index) =>
      index is int && index >= 0 && index < segments.length ? segments[index].startMs : null;
  String text(dynamic value) => value is String ? value : '';

  final progress = <Map<String, dynamic>>[];
  final seen = <int>{};
  for (final entry in (map['todo_progress'] is List ? map['todo_progress'] as List : const [])) {
    if (entry is! Map) continue;
    final index = entry['previous_todo_index'];
    if (index is! int || index < 0 || index >= previousTodos.length || !seen.add(index)) continue;
    progress.add({
      'task': previousTodos[index],
      'status': text(entry['status']),
      'note': text(entry['note']),
      'source_timestamp_ms': msFor(entry['source_segment_index']),
    });
  }
  bool unmentioned(Map<String, dynamic> p) =>
      TodoProgressStatus.fromJson(p['status'] as String?) == TodoProgressStatus.notMentioned;
  // Stable: the model's order within each group is kept.
  final ordered = [...progress.where((p) => !unmentioned(p)), ...progress.where(unmentioned)];

  return {
    'todo_progress': ordered,
    'decision_changes': [
      for (final entry in (map['decision_changes'] is List ? map['decision_changes'] as List : const []))
        if (entry is Map)
          {
            'change': text(entry['change']),
            'previous_decision': text(entry['previous_decision']),
            'current': text(entry['current']),
            'source_timestamp_ms': msFor(entry['source_segment_index']),
          },
    ],
    'new_topics': [
      for (final topic in (map['new_topics'] is List ? map['new_topics'] as List : const []))
        if (topic is String && topic.trim().isNotEmpty) topic,
    ],
  };
}
