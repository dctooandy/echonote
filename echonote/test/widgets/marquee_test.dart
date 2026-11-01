import 'package:echonote/widgets/marquee.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ScrollController?> _pump(WidgetTester tester, String text, {bool reduceMotion = false}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Center(
          child: SizedBox(width: 120, child: Marquee(child: Text(text, style: const TextStyle(fontSize: 14)))),
        ),
      ),
    ),
  );
  await tester.pump();
  return tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView)).controller;
}

void main() {
  testWidgets('a line that fits sits still, shown once', (tester) async {
    final scroll = await _pump(tester, '11/1');
    await tester.pump(const Duration(seconds: 2));
    expect(scroll!.offset, 0);
    expect(find.text('11/1'), findsOneWidget);
  });

  testWidgets('a line too long scrolls on and on, a second copy following', (tester) async {
    final scroll = await _pump(tester, '10/31 16:52 · 接續 10/23 · 12 場後續 · 還有更多文字');
    await tester.pump(const Duration(milliseconds: 500));
    final first = scroll!.offset;
    expect(first, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(scroll.offset, isNot(first));
    expect(find.textContaining('還有更多文字'), findsNWidgets(2));
    // Drop it so the ticker stops before the test ends.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with less motion asked for, it stays put', (tester) async {
    final scroll = await _pump(tester, '10/31 16:52 · 接續 10/23 · 12 場後續 · 還有更多文字', reduceMotion: true);
    await tester.pump(const Duration(seconds: 2));
    expect(scroll!.offset, 0);
    expect(find.textContaining('還有更多文字'), findsOneWidget);
  });
}
