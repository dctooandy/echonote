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

/// Meetings that follow [recording], oldest first.
List<Recording> followersOf(Recording recording, List<Recording> all) =>
    all.where((r) => r.id != recording.id && r.previousRecordingId == recording.id).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

/// How many series colors the theme has (spec feature-chain-links,
/// decision 6).
const seriesColorCount = 5;

/// Meetings tied together by following: one tree, since each meeting
/// follows at most one (spec feature-chain-links, decision 2).
class MeetingSeries {
  MeetingSeries(this.recordings, this.colorIndex);

  /// Newest first.
  final List<Recording> recordings;

  /// Into the series palette: the oldest series gets 0, the next 1, and so
  /// on, so new recordings never recolor an older series (decision 9).
  final int colorIndex;

  /// The first (oldest) meeting: where a name the user gives is kept.
  Recording get first => recordings.last;

  /// The name the user gave it, else its latest meeting's (decision 17).
  String get name => first.seriesName ?? recordings.first.displayTitle;
  DateTime get latest => recordings.first.createdAt;
  bool contains(Recording recording) => recordings.any((r) => r.id == recording.id);
}

/// Every series of two or more meetings, the one with the latest meeting
/// first. A meeting whose previous one was deleted starts a series of its
/// own.
List<MeetingSeries> seriesOf(List<Recording> all) {
  final byId = {for (final r in all) r.id: r};
  Recording rootOf(Recording r) {
    final seen = {r.id};
    var root = r;
    while (true) {
      final previous = byId[root.previousRecordingId];
      if (previous == null || !seen.add(previous.id)) return root;
      root = previous;
    }
  }

  final groups = <Recording, List<Recording>>{};
  for (final r in all) {
    groups.putIfAbsent(rootOf(r), () => []).add(r);
  }
  final roots = groups.keys.where((root) => groups[root]!.length > 1).toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  final series = [
    for (var i = 0; i < roots.length; i++)
      MeetingSeries(groups[roots[i]]!..sort((a, b) => b.createdAt.compareTo(a.createdAt)), i % seriesColorCount),
  ];
  return series..sort((a, b) => b.latest.compareTo(a.latest));
}

/// What a meeting links to, for the hint after its date in the list: the
/// day of the meeting it follows, and how many follow it (spec
/// feature-chain-links, decisions 4 and 14).
class ChainHint {
  const ChainHint({this.follows, this.followers = 0});

  /// "10/31", or null when it follows none (or that one was deleted).
  final String? follows;
  final int followers;

  bool get isEmpty => follows == null && followers == 0;
}

/// The "全部" list's hint: what it follows and how many follow it.
ChainHint chainHint(Recording recording, List<Recording> all) {
  final previous = previousOf(recording, all);
  return ChainHint(
    follows: previous == null ? null : formatMonthDay(previous.createdAt),
    followers: followersOf(recording, all).length,
  );
}

/// Inside a series frame, newest first, only a branch says what it follows:
/// a row whose previous meeting isn't the row right below it (decision 10).
ChainHint seriesRowHint(MeetingSeries series, int index) {
  final recording = series.recordings[index];
  final below = index + 1 < series.recordings.length ? series.recordings[index + 1] : null;
  final previousId = recording.previousRecordingId;
  if (previousId == null || previousId == below?.id) return const ChainHint();
  for (final r in series.recordings) {
    if (r.id == previousId) return ChainHint(follows: formatMonthDay(r.createdAt));
  }
  return const ChainHint();
}
