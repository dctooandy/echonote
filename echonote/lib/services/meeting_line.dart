import '../models/recording.dart';

// Builds the LINE message sent after a meeting (spec
// feature-meeting-to-line). Plain Dart, no plugins, no AI call: it reads the
// analysis as it stands, so edited todos show up.

const _noDue = '沒有期限';
const _thisWeek = '本週內';
const _weekdays = ['週一', '週二', '週三', '週四', '週五', '週六', '週日', '週天'];

/// Tidies the AI's free-text due date so one deadline doesn't split into
/// two groups: 「本週三前」「星期三」 both read 週三前. Null means no date.
String? normalizeDue(String? due) {
  var text = due?.trim() ?? '';
  if (const {'', '無', '未指定', '未定', '待定', '不明'}.contains(text)) return null;
  text = text.replaceAll(RegExp('星期|禮拜|周'), '週');
  if (const {'本週', '這週', '本週內', '這週內'}.contains(text)) return _thisWeek;
  text = text.replaceFirst(RegExp('^(本週|這週)(?=[一二三四五六日天])'), '週');
  if (RegExp('^週[一二三四五六日天]\$').hasMatch(text)) text = '$text前';
  return text;
}

/// A date past this week. 下週前 and 下週以前 mean done before next week.
bool isLaterDue(String? due) {
  if (due == null || const {'下週前', '下週以前'}.contains(due)) return false;
  return RegExp('下週|隔週|下個月|下月').hasMatch(due);
}

int _groupRank(String label) {
  if (label == _noDue) return 2;
  return _weekdays.any(label.startsWith) ? 0 : 1;
}

/// Todos under their deadlines: weekdays in order, then other dates as they
/// came, no date last.
List<String> _groupLines(Iterable<MapEntry<String?, String>> items) {
  final groups = <String, List<String>>{};
  for (final item in items) {
    groups.putIfAbsent(item.key ?? _noDue, () => []).add(item.value);
  }
  final labels = groups.keys.toList();
  final order = {for (final (i, label) in labels.indexed) label: i};
  labels.sort((a, b) {
    final byRank = _groupRank(a).compareTo(_groupRank(b));
    if (byRank != 0) return byRank;
    if (_groupRank(a) == 0) {
      final byDay = _weekdays.indexOf(a.substring(0, 2)).compareTo(_weekdays.indexOf(b.substring(0, 2)));
      if (byDay != 0) return byDay;
    }
    return order[a]!.compareTo(order[b]!);
  });
  return [
    for (final label in labels) ...[label, ...groups[label]!.map((line) => '・$line')],
  ];
}

/// The message without its greeting; empty when the analysis has no
/// decisions and no open todos. [myName] is null when we can't tell which
/// todos are the user's: then nothing says 麻煩您 and owners are spelled out
/// (decision 7).
String lineMessageBody(MeetingAnalysis analysis, {String? myName}) {
  final decisions = <String>{
    for (final item in analysis.agendaItems)
      for (final decision in item.decisions)
        if (decision.trim().isNotEmpty) decision.trim(),
  };

  String lineFor(Todo todo) {
    final task = todo.task.trim();
    final owner = todo.owner?.trim() ?? '';
    if (owner.isEmpty) return task;
    if (myName == null) return '$task（$owner）';
    return owner == myName ? task : '（麻煩您）$task';
  }

  final thisWeek = <MapEntry<String?, String>>[];
  final later = <MapEntry<String?, String>>[];
  for (final todo in analysis.todos) {
    if (todo.done || todo.task.trim().isEmpty) continue;
    final due = normalizeDue(todo.dueDate);
    (isLaterDue(due) ? later : thisWeek).add(MapEntry(due, lineFor(todo)));
  }

  final sections = [
    if (decisions.isNotEmpty)
      ['【您已決定的事項】', for (final (i, decision) in decisions.indexed) '${i + 1}. $decision'],
    if (thisWeek.isNotEmpty) ['【本週要做的事】', ..._groupLines(thisWeek)],
    if (later.isNotEmpty) ['【之後】', ..._groupLines(later)],
  ];
  return sections.map((lines) => lines.join('\n')).join('\n\n');
}

/// [body] with the greeting in front; no greeting without a [name].
String lineMessage(String name, String body) {
  final who = name.trim();
  return who.isEmpty ? body : '$who好，今天會議的結論整理如下：\n\n$body';
}
