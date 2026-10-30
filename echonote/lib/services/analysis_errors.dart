import 'package:cloud_functions/cloud_functions.dart';

/// The SnackBar text for a failed `analyzeMeeting` call (spec
/// feature-app-check, UI section). Our daily quota and Claude's own rate
/// limit share `resource-exhausted`; the function tells them apart with
/// `details.reason` (decision 6).
String analysisErrorMessage(Object error) {
  if (error is! FirebaseFunctionsException) return '分析失敗：$error';
  switch (error.code) {
    case 'unauthenticated':
      return '無法驗證這個 App，請確認使用的是正式版本，或稍後再試';
    case 'resource-exhausted':
      final details = error.details;
      if (details is Map && details['reason'] == 'daily_quota') {
        return '今天的分析次數已用完，明天再試';
      }
      return error.message ?? 'Claude API 額度已達上限，請稍後再試';
    case 'unavailable':
      return '網路連線有問題，請稍後再試';
    default:
      return '分析失敗：${error.message ?? error.code}';
  }
}
