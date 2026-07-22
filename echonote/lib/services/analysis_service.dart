import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';

import '../models/recording.dart';

class AnalysisService {
  Future<MeetingAnalysis> analyze(List<TranscriptSegment> segments) async {
    final callable = FirebaseFunctions.instance.httpsCallable('analyzeMeeting');
    final result = await callable.call<Map<String, dynamic>>({
      'segments': segments.map((s) => s.toJson()).toList(),
    });
    // The plugin returns nested Map<Object?, Object?> from the platform channel;
    // round-tripping through JSON normalizes it to plain Map<String, dynamic>.
    final data = jsonDecode(jsonEncode(result.data)) as Map<String, dynamic>;
    _resolveSegmentIndices(data, segments);
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
