/// How a term entered the glossary. Stored as `manual` / `learned`.
enum GlossaryTermSource {
  manual('manual'),

  /// Confirmed by the user after correcting the transcript.
  learned('learned');

  const GlossaryTermSource(this.jsonValue);

  final String jsonValue;

  static GlossaryTermSource fromJson(String? value) =>
      values.firstWhere((s) => s.jsonValue == value, orElse: () => manual);
}

/// One correctly spelled name or term the user wants transcribed right.
class GlossaryTerm {
  GlossaryTerm({
    required this.id,
    required this.term,
    required this.createdAt,
    List<String>? aliases,
    this.pinned = false,
    this.source = GlossaryTermSource.manual,
    this.projectId,
    this.lastUsedAt,
  }) : aliases = aliases ?? [];

  final String id;
  String term;

  /// Misspellings learned from transcript corrections. Recorded only; P1
  /// never auto-replaces with them.
  final List<String> aliases;
  bool pinned;
  final GlossaryTermSource source;

  /// Reserved for per-project glossaries; always null in P1.
  final String? projectId;
  final DateTime createdAt;
  DateTime? lastUsedAt;

  factory GlossaryTerm.fromJson(Map<String, dynamic> json) => GlossaryTerm(
    id: json['id'] as String,
    term: json['term'] as String,
    aliases: (json['aliases'] as List<dynamic>? ?? []).cast<String>(),
    pinned: json['pinned'] as bool? ?? false,
    source: GlossaryTermSource.fromJson(json['source'] as String?),
    projectId: json['project_id'] as String?,
    createdAt: DateTime.parse(json['created_at'] as String),
    lastUsedAt: json['last_used_at'] != null ? DateTime.parse(json['last_used_at'] as String) : null,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'term': term,
    'aliases': aliases,
    'pinned': pinned,
    'source': source.jsonValue,
    'project_id': projectId,
    'created_at': createdAt.toIso8601String(),
    'last_used_at': lastUsedAt?.toIso8601String(),
  };
}

const kGlossaryTermMaxChars = 20;
const kGlossaryMaxTerms = 200;

/// A line break would split the term in the one-per-line list sent to
/// Claude. Punctuation is allowed: names like `Apple, Inc.` need it, and in
/// the whisper prompt it only reads as part of the text.
final _forbiddenChars = RegExp(r'[\n\r]');

enum GlossaryTermError {
  empty('請輸入詞條'),
  tooLong('詞條最多 $kGlossaryTermMaxChars 字'),
  forbiddenChar('詞條不能換行'),
  duplicate('詞條已存在'),
  glossaryFull('詞庫最多 $kGlossaryMaxTerms 條');

  const GlossaryTermError(this.message);

  final String message;
}

/// Returns why [raw] can't be added to [existing], or null when it can.
/// Compares after trimming, as the stored term is trimmed too.
GlossaryTermError? validateNewTerm(String raw, List<GlossaryTerm> existing) {
  final term = raw.trim();
  if (term.isEmpty) return GlossaryTermError.empty;
  // Code points, so a CJK character counts as one.
  if (term.runes.length > kGlossaryTermMaxChars) return GlossaryTermError.tooLong;
  if (_forbiddenChars.hasMatch(term)) return GlossaryTermError.forbiddenChar;
  if (existing.any((t) => t.term == term)) return GlossaryTermError.duplicate;
  if (existing.length >= kGlossaryMaxTerms) return GlossaryTermError.glossaryFull;
  return null;
}
