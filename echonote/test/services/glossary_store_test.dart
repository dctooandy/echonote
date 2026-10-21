import 'dart:io';

import 'package:echonote/models/glossary.dart';
import 'package:echonote/services/glossary_store.dart';
import 'package:flutter_test/flutter_test.dart';

GlossaryTerm _term(String term) => GlossaryTerm(id: term, term: term, createdAt: DateTime(2026, 10, 21));

void main() {
  late Directory dir;
  late GlossaryStore store;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('glossary_test');
    store = GlossaryStore(documentsDir: () async => dir);
    file = File('${dir.path}/glossary.json');
  });

  tearDown(() => dir.delete(recursive: true));

  group('GlossaryStore', () {
    test('missing file loads as an empty glossary', () async {
      final result = await store.load();

      expect(result.terms, isEmpty);
      expect(result.isCorrupt, isFalse);
    });

    test('an empty glossary loads as a list callers can add to', () async {
      final terms = (await store.load()).terms;

      terms.add(_term('台積電'));
      expect(terms, hasLength(1));
    });

    test('added terms round-trip, trimmed', () async {
      expect(await store.add('  台積電 '), isNull);
      expect(await store.add('EchoNote'), isNull);

      final terms = (await store.load()).terms;
      expect(terms.map((t) => t.term), ['台積電', 'EchoNote']);
      expect(terms.first.source, GlossaryTermSource.manual);
      expect(terms.first.projectId, isNull);
      expect(terms.first.aliases, isEmpty);
    });

    test('corrupt file loads as empty and is never overwritten', () async {
      await file.writeAsString('{not json');

      final result = await store.load();
      expect(result.terms, isEmpty);
      expect(result.isCorrupt, isTrue);

      await expectLater(store.add('台積電'), throwsA(isA<GlossaryCorruptException>()));
      expect(await file.readAsString(), '{not json');
    });

    test('learn adds a learned term with its misspelling', () async {
      expect(await store.learn('台積電', '太基電'), isNull);

      final term = (await store.load()).terms.single;
      expect(term.term, '台積電');
      expect(term.aliases, ['太基電']);
      expect(term.source, GlossaryTermSource.learned);
      expect(term.lastUsedAt, isNotNull);
    });

    test('learning a known term adds the alias once and marks it used', () async {
      await store.add('台積電');

      await store.learn('台積電', '太基電');
      await store.learn('台積電', '太基電');
      await store.learn('台積電', '抬機電');

      final term = (await store.load()).terms.single;
      expect(term.aliases, ['太基電', '抬機電']);
      expect(term.source, GlossaryTermSource.manual);
      expect(term.lastUsedAt, isNotNull);
    });

    test('learn rejects an invalid term', () async {
      expect(await store.learn('台積\n電', '太基電'), GlossaryTermError.forbiddenChar);
      expect((await store.load()).terms, isEmpty);
    });

    test('rejected terms are not saved', () async {
      await store.add('台積電');

      expect(await store.add('台積電 '), GlossaryTermError.duplicate);
      expect((await store.load()).terms, hasLength(1));
    });
  });

  group('GlossaryTerm JSON', () {
    test('all fields round-trip', () {
      final term = GlossaryTerm(
        id: '1',
        term: '台積電',
        aliases: ['太基電'],
        pinned: true,
        source: GlossaryTermSource.learned,
        createdAt: DateTime(2026, 10, 21, 9),
        lastUsedAt: DateTime(2026, 10, 21, 10),
      );

      final back = GlossaryTerm.fromJson(term.toJson());
      expect(back.aliases, ['太基電']);
      expect(back.pinned, isTrue);
      expect(back.source, GlossaryTermSource.learned);
      expect(back.lastUsedAt, DateTime(2026, 10, 21, 10));
    });
  });

  group('validateNewTerm', () {
    test('accepts a normal term', () {
      expect(validateNewTerm('台積電', []), isNull);
    });

    test('rejects blank input', () {
      expect(validateNewTerm('   ', []), GlossaryTermError.empty);
    });

    test('counts CJK characters, not bytes, toward the 20 limit', () {
      expect(validateNewTerm('字' * 20, []), isNull);
      expect(validateNewTerm('字' * 21, []), GlossaryTermError.tooLong);
    });

    test('rejects a line break inside the term', () {
      for (final bad in ['台積\n電', '台積\r電']) {
        expect(validateNewTerm(bad, []), GlossaryTermError.forbiddenChar, reason: bad);
      }
    });

    test('accepts punctuation, as names need it', () {
      for (final ok in ['Apple, Inc.', '台積，電', '台積、電', '台積。電', 'Yahoo!']) {
        expect(validateNewTerm(ok, []), isNull, reason: ok);
      }
    });

    test('rejects a duplicate after trimming', () {
      expect(validateNewTerm(' 台積電 ', [_term('台積電')]), GlossaryTermError.duplicate);
    });

    test('rejects a new term once the glossary is full', () {
      final full = List.generate(kGlossaryMaxTerms, (i) => _term('詞$i'));

      expect(validateNewTerm('新詞', full), GlossaryTermError.glossaryFull);
    });
  });
}
