import 'dart:io';

import 'package:echonote/models/glossary.dart';
import 'package:echonote/screens/glossary_screen.dart';
import 'package:echonote/services/glossary_store.dart';
import 'package:echonote/services/whisper_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

GlossaryTerm _term(String term, {bool pinned = false, DateTime? createdAt}) => GlossaryTerm(
  id: term,
  term: term,
  pinned: pinned,
  createdAt: createdAt ?? DateTime(2026, 10, 1),
);

void main() {
  late Directory dir;
  late GlossaryStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('glossary_screen_test');
    store = GlossaryStore(documentsDir: () async => dir);
  });

  tearDown(() => dir.delete(recursive: true));

  /// The store does real file I/O in several steps, which fake time doesn't
  /// advance; and while loading, the spinner never lets pumpAndSettle
  /// return. So alternate real waits with single frames, then settle.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, {WhisperPromptMode promptMode = WhisperPromptMode.glossary}) async {
    await tester.pumpWidget(MaterialApp(home: GlossaryScreen(store: store, promptMode: promptMode)));
    await settle(tester);
  }

  testWidgets('empty glossary explains what it is for', (tester) async {
    await open(tester);

    expect(find.textContaining('加入人名、公司名'), findsOneWidget);
    expect(find.textContaining('不是它聽起來的音'), findsOneWidget);
  });

  testWidgets('the first term can be added to an empty glossary', (tester) async {
    await open(tester);

    await tester.tap(find.byTooltip('新增詞條'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '台積電');
    await tester.tap(find.text('儲存'));
    await settle(tester);

    expect(find.text('台積電'), findsOneWidget);
    expect((await tester.runAsync(store.load))!.terms.single.term, '台積電');
  });

  testWidgets('adding a term validates it, then saves it', (tester) async {
    await tester.runAsync(() => store.save([_term('台積電')]));
    await open(tester);

    await tester.tap(find.byTooltip('新增詞條'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '台積電');
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();
    expect(find.text('詞條已存在'), findsOneWidget);

    await tester.enterText(find.byType(TextField), ' EchoNote ');
    await tester.tap(find.text('儲存'));
    await settle(tester);

    final saved = (await tester.runAsync(store.load))!.terms;
    expect(saved.map((t) => t.term), ['台積電', 'EchoNote']);
    expect(saved.last.lastUsedAt, isNotNull);
  });

  testWidgets('lists pinned first and marks terms past the transcription budget', (tester) async {
    await tester.runAsync(
      () => store.save([
        _term('長' * 20, createdAt: DateTime(2026, 10, 5)),
        _term('長長' * 10, createdAt: DateTime(2026, 10, 4)),
        _term('長長長長' * 5, createdAt: DateTime(2026, 10, 3)),
        _term('長長長長長' * 4, createdAt: DateTime(2026, 10, 2)),
        _term('釘選', pinned: true, createdAt: DateTime(2020)),
      ]),
    );
    await open(tester);

    // 2 + 4 × (1 + 20) = 86 > 80: the oldest 20-character term is left out.
    expect(find.textContaining('前 4 個詞會送進語音轉錄'), findsOneWidget);
    final titles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.title as Text).data)
        .toList();
    expect(titles.first, '釘選');
    expect(find.text('只用在摘要'), findsOneWidget);
  });

  testWidgets('with layer ① off, says the glossary is only used for summaries', (tester) async {
    await tester.runAsync(() => store.save([_term('台積電')]));
    await open(tester, promptMode: WhisperPromptMode.none);

    expect(find.textContaining('語音轉錄暫時不使用詞庫'), findsOneWidget);
    expect(find.textContaining('會送進語音轉錄'), findsNothing);
  });

  testWidgets('pinning is saved', (tester) async {
    await tester.runAsync(() => store.save([_term('台積電')]));
    await open(tester);

    await tester.tap(find.byTooltip('釘選'));
    await settle(tester);

    expect((await tester.runAsync(store.load))!.terms.single.pinned, isTrue);
  });

  testWidgets('a deleted term can be restored', (tester) async {
    await tester.runAsync(() => store.save([_term('台積電'), _term('EchoNote')]));
    await open(tester);

    await tester.tap(find.byTooltip('刪除').first);
    await settle(tester);
    expect((await tester.runAsync(store.load))!.terms, hasLength(1));

    await tester.tap(find.text('復原'));
    await settle(tester);
    expect((await tester.runAsync(store.load))!.terms, hasLength(2));
  });

  testWidgets('a corrupt glossary is shown as such and cannot be edited', (tester) async {
    await tester.runAsync(() => File('${dir.path}/glossary.json').writeAsString('{not json'));
    await open(tester);

    expect(find.textContaining('詞庫檔案已損毀'), findsOneWidget);
    expect(find.byTooltip('新增詞條'), findsNothing);
  });
}
