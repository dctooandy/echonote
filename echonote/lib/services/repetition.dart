/// Collapsing the repetition loops `tiny` falls into during live preview
/// ("經常經常經常…", "Helps,Helps,…"). With temperature fallback off, nothing
/// in whisper stops a loop, so it runs to the token limit and, at a commit,
/// stays in the preview for good. The native side applies the same rules
/// before committing (`collapse_repetitions.h`); both are checked against
/// `test/fixtures/repetition_cases.json`, so keep them in step.
library;

/// Shortest and longest repeated unit, in code points, ignoring separators.
const kRepetitionMinUnit = 1;
const kRepetitionMaxUnit = 10;

/// A unit repeated this many times in a row counts as a loop.
const kRepetitionMinRepeats = 4;

/// Whitespace and punctuation between repeats ("Helps, Helps,") don't break
/// a loop. An explicit list rather than Unicode categories, so the C++ side
/// can match it exactly.
bool isRepetitionSeparator(int cp) =>
    cp <= 0x20 || // control characters and space
    (cp >= 0x21 && cp <= 0x2F) || // !"#$%&'()*+,-./
    (cp >= 0x3A && cp <= 0x40) || // :;<=>?@
    (cp >= 0x5B && cp <= 0x60) || // [\]^_`
    (cp >= 0x7B && cp <= 0x7E) || // {|}~
    (cp >= 0x2010 && cp <= 0x2027) || // dashes, quotes, ellipsis
    (cp >= 0x3000 && cp <= 0x303F) || // CJK space and punctuation 、。「」
    (cp >= 0xFF01 && cp <= 0xFF0F) || // fullwidth ！＂…／ incl. ，
    (cp >= 0xFF1A && cp <= 0xFF20) || // fullwidth ：；＜＝＞？＠
    (cp >= 0xFF3B && cp <= 0xFF40) ||
    (cp >= 0xFF5B && cp <= 0xFF65);

/// Stands in for a character whisper split across tokens and the run cut in
/// half; the native side turns the leftover bytes into it.
const _replacementChar = 0xFFFD;

/// [text] with every loop (a unit of [kRepetitionMinUnit]–[kRepetitionMaxUnit]
/// code points repeated [kRepetitionMinRepeats]+ times in a row, separators
/// ignored) cut down to its first occurrence, and every U+FFFD dropped;
/// everything else is kept as is. [collapsed] counts the loops removed.
({String text, int collapsed}) collapseRepetitions(String text) {
  final runes = text.runes.where((cp) => cp != _replacementChar).toList();
  // The text without separators, and where each of its code points sits in
  // [runes].
  final core = <int>[];
  final at = <int>[];
  for (var i = 0; i < runes.length; i++) {
    if (isRepetitionSeparator(runes[i])) continue;
    core.add(runes[i]);
    at.add(i);
  }

  final out = StringBuffer();
  var copiedUpTo = 0; // index into runes
  var collapsed = 0;
  var i = 0;
  while (i < core.length) {
    final loop = _loopAt(core, i);
    if (loop == null) {
      i++;
      continue;
    }
    final (:unit, :repeats) = loop;
    // Keep through the end of the first unit, drop the rest of the loop, and
    // carry on from what follows its last unit (a trailing separator stays).
    final firstEnd = at[i + unit - 1] + 1;
    final loopEnd = at[i + unit * repeats - 1] + 1;
    out.write(String.fromCharCodes(runes.sublist(copiedUpTo, firstEnd)));
    copiedUpTo = loopEnd;
    collapsed++;
    i += unit * repeats;
  }
  out.write(String.fromCharCodes(runes.sublist(copiedUpTo)));
  return (text: out.toString(), collapsed: collapsed);
}

/// The shortest unit starting at [start] that repeats enough times, with how
/// many times it repeats.
({int unit, int repeats})? _loopAt(List<int> core, int start) {
  for (var unit = kRepetitionMinUnit; unit <= kRepetitionMaxUnit; unit++) {
    if (start + unit * kRepetitionMinRepeats > core.length) break;
    var repeats = 1;
    while (start + unit * (repeats + 1) <= core.length &&
        _sameUnit(core, start, start + unit * repeats, unit)) {
      repeats++;
    }
    if (repeats >= kRepetitionMinRepeats) return (unit: unit, repeats: repeats);
  }
  return null;
}

bool _sameUnit(List<int> core, int a, int b, int length) {
  for (var k = 0; k < length; k++) {
    if (core[a + k] != core[b + k]) return false;
  }
  return true;
}
