import 'package:echonote/models/recording.dart';
import 'package:echonote/services/analysis_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final segments = [TranscriptSegment(startMs: 0, endMs: 1000, text: '我週三前修好')];

  test('my_name is sent trimmed when given (spec feature-my-name)', () {
    expect(buildAnalysisRequest(segments, myName: ' Andy ').request['my_name'], 'Andy');
  });

  test('no name, or a blank one, sends no my_name', () {
    expect(buildAnalysisRequest(segments).request.containsKey('my_name'), isFalse);
    expect(buildAnalysisRequest(segments, myName: '  ').request.containsKey('my_name'), isFalse);
  });
}
