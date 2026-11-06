import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/recording.dart';
import '../services/app_settings.dart';
import '../services/meeting_line.dart';

/// Shows the LINE message for one meeting, to read and change before it's
/// copied (spec feature-meeting-to-line). Nothing is kept: leaving the page
/// drops the edits.
class LineMessageScreen extends StatefulWidget {
  const LineMessageScreen({super.key, required this.recording});

  final Recording recording;

  @override
  State<LineMessageScreen> createState() => _LineMessageScreenState();
}

class _LineMessageScreenState extends State<LineMessageScreen> {
  // Name and body stay apart, so changing the name keeps an edited body.
  final _name = TextEditingController();
  final _body = TextEditingController();
  var _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final settings = AppSettingsScope.of(context);
    final recording = widget.recording;
    _name.text = settings.lineGreetingName ?? '';
    _body.text = lineMessageBody(
      recording.analysis!,
      myName: recording.iAttended ? settings.myName : null,
    );
    _body.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    final settings = AppSettingsScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: lineMessage(_name.text, _body.text)));
    messenger.showSnackBar(const SnackBar(content: Text('已複製到剪貼簿')));
    try {
      await settings.setLineGreetingName(_name.text);
    } catch (_) {
      // Remembering the name is a convenience; the copy already worked.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recording = widget.recording;
    final stale = recording.transcriptStaleAnalysis || recording.previousChangedSinceAnalysis;
    final empty = _body.text.trim().isEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('LINE 訊息')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (stale) ...[
                Text(
                  '逐字稿或接續的會議改過，這則訊息可能過時；重新分析後才會更新。',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '稱呼', helperText: '例如「陳醫師」；沒填就不寫問候那一行'),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TextField(
                  controller: _body,
                  expands: true,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '這場沒有整理出決定和待辦',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: empty ? null : _copy,
                icon: const Icon(Icons.copy),
                label: const Text('複製'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
