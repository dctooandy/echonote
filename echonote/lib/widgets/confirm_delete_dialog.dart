import 'package:flutter/material.dart';

import '../models/recording.dart';

/// Asks before deleting [recording]; resolves to true only on "刪除".
Future<bool> confirmDeleteRecording(BuildContext context, Recording recording) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('刪除這筆紀錄？'),
      content: Text('「${recording.displayTitle}」的逐字稿、分析結果和錄音檔都會一起刪除，無法復原。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          child: const Text('刪除'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
