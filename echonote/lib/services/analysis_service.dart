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
    return MeetingAnalysis.fromJson(data);
  }
}
