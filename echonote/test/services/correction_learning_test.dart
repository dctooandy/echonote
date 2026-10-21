import 'package:echonote/models/recording.dart';
import 'package:echonote/services/correction_learning.dart';
import 'package:flutter_test/flutter_test.dart';

TranscriptSegment _segment(String text) => TranscriptSegment(startMs: 0, endMs: 1, text: text);

void main() {
  group('detectReplacement', () {
    test('finds the changed span, leaving shared characters out', () {
      final r = detectReplacement('太基電的報價', '台積電的報價')!;

      expect(r.before, '太基');
      expect(r.after, '台積');
      expect(r.key, '太基→台積');
    });

    test('handles a replacement of a different length', () {
      final r = detectReplacement('下週依可諾要送審', '下週EchoNote要送審')!;

      expect(r.before, '依可諾');
      expect(r.after, 'EchoNote');
    });

    test('a single-character change is not offered', () {
      expect(detectReplacement('他說好', '她說好'), isNull);
    });

    test('more than ten characters on either side is not offered', () {
      expect(detectReplacement('甲一二三四五六七八九十乙', '甲ABCDEFGHIJK乙'), isNull);
    });

    test('two separate edits are not offered', () {
      expect(detectReplacement('太基電和王曉明', '台積電和王小明'), isNull);
    });

    test('a pure insertion or deletion is not offered', () {
      expect(detectReplacement('報價', '新的報價'), isNull);
      expect(detectReplacement('新的報價', '報價'), isNull);
    });
  });

  group('expandToTerm', () {
    test('widens the misspelling the same way the term was widened', () {
      final r = expandToTerm(const Replacement('太基', '台積'), '台積電');

      expect(r.before, '太基電');
      expect(r.after, '台積電');
    });

    test('works on both sides', () {
      final r = expandToTerm(const Replacement('基', '積'), '台積電');

      expect(r.before, '台基電');
    });

    test('an unrelated term keeps the detected misspelling', () {
      final r = expandToTerm(const Replacement('依可諾', 'EchoNote'), '迴聲筆記');

      expect(r.before, '依可諾');
      expect(r.after, '迴聲筆記');
    });
  });

  group('countOccurrences / replaceInSegments', () {
    test('count every other segment, skipping the edited one', () {
      final edited = _segment('台積電');
      final segments = [edited, _segment('太基電太基電'), _segment('沒有')];

      expect(countOccurrences(segments, '太基電', except: edited), 2);
    });

    test('replace marks only the changed segments as edited', () {
      final edited = _segment('台積電');
      final untouched = _segment('沒有');
      final segments = [edited, _segment('太基電說太基電'), untouched];

      expect(replaceInSegments(segments, '太基電', '台積電', except: edited), 2);
      expect(segments[1].text, '台積電說台積電');
      expect(segments[1].edited, isTrue);
      expect(untouched.edited, isFalse);
      expect(edited.edited, isFalse);
    });
  });
}
