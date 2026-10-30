import 'package:cloud_functions/cloud_functions.dart';
import 'package:echonote/services/analysis_errors.dart';
import 'package:flutter_test/flutter_test.dart';

FirebaseFunctionsException _error(String code, {String? message, dynamic details}) =>
    FirebaseFunctionsException(code: code, message: message ?? '', details: details);

void main() {
  test('App Check rejection asks the user to check the build', () {
    expect(analysisErrorMessage(_error('unauthenticated')), '無法驗證這個 App，請確認使用的是正式版本，或稍後再試');
  });

  test('our daily quota is told apart by details.reason', () {
    expect(
      analysisErrorMessage(_error('resource-exhausted', details: {'reason': 'daily_quota'})),
      '今天的分析次數已用完，明天再試',
    );
  });

  test("Claude's rate limit keeps the function's message", () {
    expect(
      analysisErrorMessage(_error('resource-exhausted', message: 'Claude API 額度已達上限，請稍後再試')),
      'Claude API 額度已達上限，請稍後再試',
    );
  });

  test('unavailable reads as a connection problem', () {
    expect(analysisErrorMessage(_error('unavailable')), '網路連線有問題，請稍後再試');
  });

  test('other codes show the function message', () {
    expect(analysisErrorMessage(_error('internal', message: 'Claude API 沒有回傳文字內容')), '分析失敗：Claude API 沒有回傳文字內容');
  });

  test('non-Firebase errors still show something', () {
    expect(analysisErrorMessage(StateError('boom')), '分析失敗：Bad state: boom');
  });
}
