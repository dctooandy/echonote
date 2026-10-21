import '../models/recording.dart';

/// The one span a transcript correction replaced, e.g. `太基` → `台積`.
class Replacement {
  const Replacement(this.before, this.after);

  final String before;
  final String after;

  /// How a declined replacement is remembered in
  /// [Recording.dismissedReplacements].
  String get key => '$before→$after';
}

/// Shortest and longest replacement worth offering to learn. Single
/// characters (他／她, 的／得) are ordinary typos, not names.
const kLearnMinChars = 2;
const kLearnMaxChars = 10;

/// The replacement turning [before] into [after], when the edit is exactly
/// one contiguous replacement with both sides [kLearnMinChars]–
/// [kLearnMaxChars] characters long; otherwise null (several edits, a pure
/// insertion or deletion, or a span too short or long).
///
/// Diffs by code point, so the span is the smallest one that changed:
/// `太基電` → `台積電` gives `太基` → `台積`, since `電` is common to both.
/// [expandToTerm] widens it once the user says where the word ends.
Replacement? detectReplacement(String before, String after) {
  final a = before.runes.toList();
  final b = after.runes.toList();

  // Longest common subsequence table, then walk it to mark which code
  // points of each side are kept.
  final lcs = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : _max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }

  // Each hunk is a run of removed and/or added code points between kept ones.
  final hunks = <({List<int> removed, List<int> added})>[];
  var removed = <int>[];
  var added = <int>[];
  void closeHunk() {
    if (removed.isEmpty && added.isEmpty) return;
    hunks.add((removed: removed, added: added));
    removed = [];
    added = [];
  }

  var i = 0;
  var j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] == b[j]) {
      closeHunk();
      i++;
      j++;
    } else if (j < b.length && (i == a.length || lcs[i][j + 1] >= lcs[i + 1][j])) {
      added.add(b[j++]);
    } else {
      removed.add(a[i++]);
    }
  }
  closeHunk();

  if (hunks.length != 1) return null;
  final hunk = hunks.single;
  bool fits(List<int> span) => span.length >= kLearnMinChars && span.length <= kLearnMaxChars;
  if (!fits(hunk.removed) || !fits(hunk.added)) return null;
  return Replacement(String.fromCharCodes(hunk.removed), String.fromCharCodes(hunk.added));
}

int _max(int x, int y) => x > y ? x : y;

/// Widens [r] to the word the user settled on: when [term] contains
/// [Replacement.after], whatever surrounds it there surrounds
/// [Replacement.before] too. `太基` → `台積` with term `台積電` gives
/// `太基電` → `台積電`. A term that doesn't contain it leaves the misspelling
/// as detected.
Replacement expandToTerm(Replacement r, String term) {
  final at = term.indexOf(r.after);
  if (at < 0) return Replacement(r.before, term);
  final prefix = term.substring(0, at);
  final suffix = term.substring(at + r.after.length);
  return Replacement('$prefix${r.before}$suffix', term);
}

/// Non-overlapping occurrences of [pattern] in every segment but [except].
int countOccurrences(List<TranscriptSegment> segments, String pattern, {TranscriptSegment? except}) {
  if (pattern.isEmpty) return 0;
  var count = 0;
  for (final segment in segments) {
    if (identical(segment, except)) continue;
    count += pattern.allMatches(segment.text).length;
  }
  return count;
}

/// Replaces [from] with [to] in every segment but [except], marking the
/// segments it changed as edited. Returns how many occurrences it replaced.
int replaceInSegments(
  List<TranscriptSegment> segments,
  String from,
  String to, {
  TranscriptSegment? except,
}) {
  if (from.isEmpty) return 0;
  var count = 0;
  for (final segment in segments) {
    if (identical(segment, except)) continue;
    final hits = from.allMatches(segment.text).length;
    if (hits == 0) continue;
    segment
      ..text = segment.text.replaceAll(from, to)
      ..edited = true;
    count += hits;
  }
  return count;
}
