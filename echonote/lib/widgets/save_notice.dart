import 'package:flutter/material.dart';

/// Runs [save]; when it fails, says so with a way to try again. Takes the
/// messenger rather than a context, so the notice and the retry still work
/// after the page is gone (spec fix-save-failure-notice, decision 1). False
/// when this attempt failed.
Future<bool> saveWithNotice(
  ScaffoldMessengerState messenger,
  Future<void> Function() save, {
  String failureMessage = '存檔失敗，這次的修改還沒保存',
}) async {
  try {
    await save();
    return true;
  } catch (_) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(failureMessage),
          action: SnackBarAction(
            label: '再試一次',
            onPressed: () async {
              if (await saveWithNotice(messenger, save, failureMessage: failureMessage)) {
                messenger
                  ..hideCurrentSnackBar()
                  ..showSnackBar(const SnackBar(content: Text('已保存')));
              }
            },
          ),
        ),
      );
    return false;
  }
}
