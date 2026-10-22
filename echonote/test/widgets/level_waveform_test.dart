import 'dart:async';

import 'package:echonote/widgets/level_waveform.dart';
import 'package:echonote/widgets/recording_dot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('levelToHeight', () {
    test('maps -60..0 dBFS to 0..1 and clamps outside it', () {
      expect(levelToHeight(0), 0);
      expect(levelToHeight(0.001), closeTo(0, 1e-9)); // -60 dBFS
      expect(levelToHeight(0.0001), 0); // -80 dBFS, below the floor
      expect(levelToHeight(0.1), closeTo(2 / 3, 1e-9)); // -20 dBFS
      expect(levelToHeight(1), 1);
      expect(levelToHeight(2), 1);
    });
  });

  group('LevelHistory', () {
    test('starts flat at full length', () {
      expect(LevelHistory().heights, List.filled(60, 0.0));
    });

    test('newest level is last; the left stays flat until it fills up', () {
      final history = LevelHistory(capacity: 3)..add(1);

      expect(history.heights, [0.0, 0.0, 1.0]);
    });

    test('drops the oldest level once full', () {
      final history = LevelHistory(capacity: 2)
        ..add(1)
        ..add(0.1)
        ..add(0.001);

      expect(history.heights, [closeTo(2 / 3, 1e-9), closeTo(0, 1e-9)]);
    });
  });

  testWidgets('the waveform takes levels from the stream', (tester) async {
    final levels = StreamController<double>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LevelWaveform(levels: levels.stream))));

    levels.add(1);
    await tester.pump();

    expect(find.bySemanticsLabel('輸入音量波形'), findsOneWidget);
    await levels.close();
  });

  Future<void> pumpDot(WidgetTester tester, {required bool reduceMotion, bool active = true}) =>
      tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: RecordingDot(active: active),
          ),
        ),
      );

  double opacity(WidgetTester tester) =>
      tester.widget<FadeTransition>(find.byType(FadeTransition).last).opacity.value;

  testWidgets('the recording dot breathes', (tester) async {
    await pumpDot(tester, reduceMotion: false);
    await tester.pump(const Duration(milliseconds: 250));

    expect(tester.hasRunningAnimations, isTrue);
    expect(opacity(tester), lessThan(1));
  });

  testWidgets('with reduce motion the dot stays solid', (tester) async {
    await pumpDot(tester, reduceMotion: true);
    await tester.pump(const Duration(milliseconds: 250));

    expect(tester.hasRunningAnimations, isFalse);
    expect(opacity(tester), 1);
  });

  testWidgets('an inactive dot stays solid', (tester) async {
    await pumpDot(tester, reduceMotion: false, active: false);
    await tester.pump(const Duration(milliseconds: 250));

    expect(tester.hasRunningAnimations, isFalse);
    expect(opacity(tester), 1);
  });
}
