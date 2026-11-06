import 'package:flutter/material.dart';

/// What the user is sharing a meeting for (spec feature-share, decision 2).
enum ShareChoice { conclusion, minutes, fullData }

/// Asks what to share. Null when dismissed.
Future<ShareChoice?> showShareSheet(
  BuildContext context, {
  required bool hasAnalysis,
  required bool hasFullData,
}) {
  return showModalBottomSheet<ShareChoice>(
    context: context,
    builder: (context) {
      Widget row(ShareChoice choice, IconData icon, String title, String subtitle, {required bool enabled}) => ListTile(
        enabled: enabled,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        onTap: () => Navigator.pop(context, choice),
      );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('要分享什麼？', style: Theme.of(context).textTheme.titleMedium),
            ),
            row(
              ShareChoice.conclusion,
              Icons.chat_bubble_outline,
              '傳給對方的結論',
              hasAnalysis ? '決定和待辦，可以改字再複製' : '分析完才能使用',
              enabled: hasAnalysis,
            ),
            row(
              ShareChoice.minutes,
              Icons.description_outlined,
              '會議紀錄',
              hasAnalysis ? '給沒參加的人，PDF 檔' : '分析完才能使用',
              enabled: hasAnalysis,
            ),
            row(
              ShareChoice.fullData,
              Icons.folder_outlined,
              '完整資料',
              hasFullData ? '逐字稿，可以加上錄音' : '沒有逐字稿，也找不到錄音檔',
              enabled: hasFullData,
            ),
          ],
        ),
      );
    },
  );
}

/// Asks which raw files to send. The recording is off by default and asks
/// once more when sent, because it can't be taken back (decisions 5, 14).
/// Null when dismissed or not confirmed.
Future<({bool transcript, bool audio})?> showFullDataSheet(
  BuildContext context, {
  required bool hasTranscript,
  required String? audioSize,
}) {
  return showModalBottomSheet<({bool transcript, bool audio})>(
    context: context,
    builder: (context) => _FullDataSheet(hasTranscript: hasTranscript, audioSize: audioSize),
  );
}

class _FullDataSheet extends StatefulWidget {
  const _FullDataSheet({required this.hasTranscript, required this.audioSize});

  final bool hasTranscript;

  /// Null when the recording's file can't be found.
  final String? audioSize;

  @override
  State<_FullDataSheet> createState() => _FullDataSheetState();
}

class _FullDataSheetState extends State<_FullDataSheet> {
  late bool _transcript = widget.hasTranscript;
  var _audio = false;

  Future<void> _share() async {
    if (_audio) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('要傳錄音嗎？'),
          content: const Text('錄音含所有發言，傳出去就收不回來。確定要傳嗎？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('確定要傳')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    Navigator.pop(context, (transcript: _transcript, audio: _audio));
  }

  @override
  Widget build(BuildContext context) {
    final audioSize = widget.audioSize;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('完整資料', style: Theme.of(context).textTheme.titleMedium),
          ),
          CheckboxListTile(
            value: _transcript,
            onChanged: widget.hasTranscript ? (value) => setState(() => _transcript = value!) : null,
            title: const Text('逐字稿'),
            subtitle: Text(widget.hasTranscript ? 'TXT 檔' : '還沒轉錄'),
          ),
          CheckboxListTile(
            value: _audio,
            onChanged: audioSize != null ? (value) => setState(() => _audio = value!) : null,
            title: const Text('原始錄音'),
            subtitle: Text(audioSize != null ? '$audioSize，含所有發言' : '找不到錄音檔'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: FilledButton(
              onPressed: _transcript || _audio ? _share : null,
              child: const Text('分享'),
            ),
          ),
        ],
      ),
    );
  }
}
