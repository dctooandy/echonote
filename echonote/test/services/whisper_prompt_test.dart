import 'package:echonote/models/glossary.dart';
import 'package:echonote/services/whisper_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

GlossaryTerm _term(
  String term, {
  bool pinned = false,
  DateTime? createdAt,
  DateTime? lastUsedAt,
}) => GlossaryTerm(
  id: term,
  term: term,
  pinned: pinned,
  createdAt: createdAt ?? DateTime(2026, 10, 1),
  lastUsedAt: lastUsedAt,
);

void main() {
  group('buildWhisperPrompt', () {
    test('empty glossary gives only the lead sentence', () {
      expect(buildWhisperPrompt([]), '以下是繁體中文的會議逐字稿。');
    });

    test('lists terms after the lead sentence', () {
      expect(
        buildWhisperPrompt([_term('台積電'), _term('王小明', createdAt: DateTime(2026, 9, 1))]),
        '以下是繁體中文的會議逐字稿，會提到：台積電、王小明。',
      );
    });
  });

  group('selectPromptTerms', () {
    test('orders pinned, then recently used, then recently added', () {
      final terms = [
        _term('舊的', createdAt: DateTime(2026, 1, 1)),
        _term('新的', createdAt: DateTime(2026, 10, 1)),
        _term('用過', createdAt: DateTime(2026, 1, 1), lastUsedAt: DateTime(2026, 10, 20)),
        _term('最近用過', createdAt: DateTime(2026, 1, 1), lastUsedAt: DateTime(2026, 10, 21)),
        _term('釘選', pinned: true, createdAt: DateTime(2025, 1, 1)),
      ];

      expect(selectPromptTerms(terms).map((t) => t.term), ['釘選', '最近用過', '用過', '新的', '舊的']);
    });

    test('a term that exactly fills the budget is kept', () {
      // 3 + 1 (、) + 3 = 7
      final terms = [_term('台積電'), _term('王小明', createdAt: DateTime(2026, 9, 1))];

      expect(selectPromptTerms(terms, maxChars: 7), hasLength(2));
      expect(selectPromptTerms(terms, maxChars: 6).map((t) => t.term), ['台積電']);
    });

    test('stops at the first term over budget instead of skipping it', () {
      final terms = [
        _term('長長長長長', createdAt: DateTime(2026, 10, 2)),
        _term('短', createdAt: DateTime(2026, 10, 1)),
      ];

      expect(selectPromptTerms(terms, maxChars: 4), isEmpty);
    });

    test('does not reorder the caller\'s list', () {
      final terms = [_term('甲', createdAt: DateTime(2026, 1, 1)), _term('乙')];

      selectPromptTerms(terms);
      expect(terms.map((t) => t.term), ['甲', '乙']);
    });
  });
}
