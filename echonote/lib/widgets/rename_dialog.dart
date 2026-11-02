import 'package:flutter/material.dart';

/// The longest name a meeting or series can have (spec feature-rename,
/// decision 8).
const nameMaxChars = 60;

/// Asks for a new name; [helper] says what clearing it goes back to. Null
/// when cancelled, else what was typed (maybe empty).
Future<String?> showRenameDialog(
  BuildContext context, {
  required String title,
  required String initial,
  required String helper,
  int maxChars = nameMaxChars,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: maxChars,
        decoration: InputDecoration(helperText: helper, helperMaxLines: 2),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('儲存')),
      ],
    ),
  );
}
