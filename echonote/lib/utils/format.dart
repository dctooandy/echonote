import 'dart:math';

String formatMs(int ms) => formatDuration(Duration(milliseconds: ms));

String formatDuration(Duration d) {
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// A recording's length for the list: m:ss, or h:mm:ss from an hour up.
/// Rounded to the second, like Voice Memos; anything shorter than a second
/// still reads 0:01.
String formatLength(int ms) {
  final total = ms <= 0 ? 0 : max(1, (ms / 1000).round());
  final h = total ~/ 3600;
  final m = total ~/ 60 % 60;
  final s = (total % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// When a recording was made, for the list: down to the minute, with the
/// year only when it isn't [now]'s.
String formatListDate(DateTime t, DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  final day = '${t.month}/${t.day} ${two(t.hour)}:${two(t.minute)}';
  return t.year == now.year ? day : '${t.year}/$day';
}
