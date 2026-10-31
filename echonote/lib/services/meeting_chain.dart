import '../models/recording.dart';
import '../utils/format.dart';

/// Meetings [current] may follow: created before it, newest first. Earlier
/// only, so following can never loop. Unanalyzed ones are included; the
/// picker shows them disabled (spec feature-cross-meeting-memory, decision 2).
List<Recording> previousCandidates(Recording current, List<Recording> all) =>
    all.where((r) => r.id != current.id && r.createdAt.isBefore(current.createdAt)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

/// The meeting [current] follows, or null when it follows none or that one
/// was deleted.
Recording? previousOf(Recording current, List<Recording> all) {
  final id = current.previousRecordingId;
  if (id == null) return null;
  for (final r in all) {
    if (r.id == id) return r;
  }
  return null;
}

/// How many earlier meetings an analysis looks back on (spec decision 3).
const previousChainMax = 3;

/// The analyzed meetings [current] follows, oldest first, at most
/// [previousChainMax]: follows the links back and stops at a deleted or
/// unanalyzed meeting.
List<Recording> previousChain(Recording current, List<Recording> all) {
  final chain = <Recording>[];
  final seen = {current.id};
  var previous = previousOf(current, all);
  while (previous != null &&
      previous.analysis != null &&
      chain.length < previousChainMax &&
      seen.add(previous.id)) {
    chain.add(previous);
    previous = previousOf(previous, all);
  }
  return chain.reversed.toList();
}

// Same limits the function checks (spec decision 4); counted in code
// points, like the function.
const previousOverviewMaxChars = 500;
const previousDecisionsMax = 20;
const previousTodosMax = 30;
const previousItemMaxChars = 200;

String _cut(String text, int max) {
  final trimmed = text.trim();
  final runes = trimmed.runes;
  return runes.length <= max ? trimmed : String.fromCharCodes(runes.take(max));
}

/// One entry of the request's `previous_meetings`: [recording]'s
/// conclusions as they are now (including the user's edits and ticks),
/// trimmed to the limits. Never its transcript, notes, attendees or own
/// follow-up (spec decisions 14 and 16). [recording] must be analyzed.
Map<String, dynamic> toPreviousMeetingPayload(Recording recording) {
  final analysis = recording.analysis!;
  return {
    'title': _cut(recording.displayTitle, previousItemMaxChars),
    'date': formatIsoDate(recording.createdAt),
    'overview': _cut(analysis.overview, previousOverviewMaxChars),
    'decisions': analysis.agendaItems
        .expand((a) => a.decisions)
        .where((d) => d.trim().isNotEmpty)
        .take(previousDecisionsMax)
        .map((d) => _cut(d, previousItemMaxChars))
        .toList(),
    'todos': analysis.todos
        .take(previousTodosMax)
        .map((t) => {
              'task': _cut(t.task, previousItemMaxChars),
              'owner': t.owner == null ? null : _cut(t.owner!, previousItemMaxChars),
              'done': t.done,
            })
        .toList(),
  };
}
