import '../models/glossary.dart';

/// Kept in every prompt: without it whisper drifts into Simplified Chinese.
const kTranscriptPromptLead = '以下是繁體中文的會議逐字稿';

/// What offline transcription sends whisper as its initial prompt.
enum WhisperPromptMode {
  /// No prompt: whisper's own behavior, as before the glossary existed.
  none,

  /// Only [kTranscriptPromptLead].
  lead,

  /// The lead plus the glossary (layer ①).
  glossary;

  static WhisperPromptMode parse(String value) =>
      values.firstWhere((m) => m.name == value, orElse: () => none);
}

/// Layer ① is off by default: on device, glossary terms came out *less*
/// accurate with the prompt than without (spec T4, 2026-10-21). Compare on
/// the same recording with
///   flutter run --release --dart-define=WHISPER_PROMPT=none|lead|glossary
final kWhisperPromptMode = WhisperPromptMode.parse(
  const String.fromEnvironment('WHISPER_PROMPT', defaultValue: 'none'),
);

/// Budget, in characters, for the glossary part of the prompt (the fixed
/// lead and separators around it aren't counted). Whisper caps the prompt
/// at ~224 tokens and a CJK character can take more than one, so this is a
/// provisional value to re-measure on device (spec task T4).
const kGlossaryPromptMaxChars = 80;

/// A copy of [terms], highest priority first: pinned, then most recently
/// used, then most recently added.
List<GlossaryTerm> sortByPromptPriority(List<GlossaryTerm> terms) => [...terms]..sort(_byPriority);

/// The terms that fit into the prompt, in [sortByPromptPriority] order.
/// Stops at the first term that would exceed [maxChars] rather than
/// skipping it, so a lower priority term never displaces a higher one.
List<GlossaryTerm> selectPromptTerms(
  List<GlossaryTerm> terms, {
  int maxChars = kGlossaryPromptMaxChars,
}) {
  final selected = <GlossaryTerm>[];
  var used = 0;
  for (final term in sortByPromptPriority(terms)) {
    // `、` between terms counts toward the budget.
    final cost = term.term.runes.length + (selected.isEmpty ? 0 : 1);
    if (used + cost > maxChars) break;
    selected.add(term);
    used += cost;
  }
  return selected;
}

/// `以下是繁體中文的會議逐字稿，會提到：A、B、C。`, or just the lead sentence when
/// no term fits.
String buildWhisperPrompt(List<GlossaryTerm> terms, {int maxChars = kGlossaryPromptMaxChars}) {
  final selected = selectPromptTerms(terms, maxChars: maxChars);
  if (selected.isEmpty) return '$kTranscriptPromptLead。';
  return '$kTranscriptPromptLead，會提到：${selected.map((t) => t.term).join('、')}。';
}

int _byPriority(GlossaryTerm a, GlossaryTerm b) {
  if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
  final used = _newestFirst(a.lastUsedAt, b.lastUsedAt);
  if (used != 0) return used;
  return b.createdAt.compareTo(a.createdAt);
}

/// Newer first; a missing date sorts after any date.
int _newestFirst(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}
