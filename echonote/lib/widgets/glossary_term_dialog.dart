import 'package:flutter/material.dart';

import '../models/glossary.dart';

/// Asks for a term's correct spelling and validates it against [others]
/// before closing; pops the trimmed term, or null when cancelled. Owns its
/// text controller, so the field outlives the closing animation.
class GlossaryTermDialog extends StatefulWidget {
  const GlossaryTermDialog({super.key, required this.title, required this.others, this.initial});

  final String title;
  final String? initial;
  final List<GlossaryTerm> others;

  @override
  State<GlossaryTermDialog> createState() => _GlossaryTermDialogState();
}

class _GlossaryTermDialogState extends State<GlossaryTermDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final error = validateNewTerm(_controller.text, widget.others);
    if (error != null) {
      setState(() => _error = error.message);
      return;
    }
    Navigator.pop(context, _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: '例如：EchoNote、台積電',
          helperText: '填正確寫法，不是聽起來的音',
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(onPressed: _submit, child: const Text('儲存')),
      ],
    );
  }
}
