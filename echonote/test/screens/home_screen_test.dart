import 'dart:convert';
import 'dart:io';

import 'package:echonote/screens/home_screen.dart';
import 'package:echonote/screens/live_record_screen.dart';
import 'package:echonote/services/app_settings.dart';
import 'package:echonote/services/audio_duration_probe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

/// Lengths by audio file name; a missing name reads as unreadable.
class _FakeProbe implements AudioDurationProbe {
  _FakeProbe(this.lengths);

  final Map<String, int> lengths;
  final asked = <String>[];

  @override
  Future<int?> durationMs(String path) async {
    final name = path.split('/').last;
    asked.add(name);
    return lengths[name];
  }
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('home_screen_test');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
  });

  tearDown(() => dir.delete(recursive: true));

  void writeEntry(String id, {int? durationMs}) {
    final history = Directory('${dir.path}/history')..createSync(recursive: true);
    File('${history.path}/$id.json').writeAsStringSync(jsonEncode({
      'id': id,
      'audio_name': '錄音 $id',
      'created_at': '2026-10-22T14:30:05.000',
      'audio_file_name': '$id.wav',
      'segments': [],
      'duration_ms': ?durationMs,
    }));
  }

  /// Lets the real file reads behind the list finish between frames.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('each entry shows its length under the status, when known', (tester) async {
    writeEntry('1', durationMs: 44 * 60000 + 12000);
    writeEntry('2', durationMs: 3600000 + 5 * 60000 + 30000);
    writeEntry('3');

    await tester.pumpWidget(MaterialApp(home: HomeScreen(durationProbe: _FakeProbe({}))));
    await settle(tester);

    expect(find.text('44:12'), findsOneWidget);
    expect(find.text('1:05:30'), findsOneWidget);
    expect(find.text('未轉錄'), findsNWidgets(3), reason: 'the status stays, length or not');
    expect(find.textContaining('14:30'), findsNWidgets(3), reason: 'the date alone, under the title');
  });

  Map<String, dynamic> saved(String id) =>
      jsonDecode(File('${dir.path}/history/$id.json').readAsStringSync()) as Map<String, dynamic>;

  testWidgets('entries without a length get it from the audio file, and keep it', (tester) async {
    writeEntry('1', durationMs: 60000);
    writeEntry('2');
    writeEntry('3');
    final probe = _FakeProbe({'1.wav': 1, '2.wav': 5 * 60000 + 3000});

    await tester.pumpWidget(MaterialApp(home: HomeScreen(durationProbe: probe)));
    await settle(tester);
    await settle(tester); // one file read and write per entry

    expect(probe.asked, unorderedEquals(['2.wav', '3.wav']), reason: 'a known length is not read again');
    expect(find.text('5:03'), findsOneWidget);
    expect(saved('2')['duration_ms'], 5 * 60000 + 3000);
    expect(saved('3').containsKey('duration_ms'), isFalse, reason: 'unreadable: nothing saved');
    expect(find.text('1:00'), findsOneWidget);
  });

  Future<void> openWith(WidgetTester tester, Handedness hand) async {
    await tester.pumpWidget(
      AppSettingsScope(
        settings: AppSettings(handedness: hand),
        child: MaterialApp(home: HomeScreen(durationProbe: _FakeProbe({}))),
      ),
    );
    await settle(tester);
  }

  testWidgets('the record button sits under the right thumb by default', (tester) async {
    await openWith(tester, Handedness.right);

    final width = tester.getSize(find.byType(HomeScreen)).width;
    expect(tester.getCenter(find.byTooltip('開始錄音')).dx, greaterThan(width / 2));
    expect(tester.getCenter(find.byTooltip('匯入錄音檔')).dx, greaterThan(width / 2));
  });

  testWidgets('left-handed puts the buttons on the left', (tester) async {
    await openWith(tester, Handedness.left);

    final width = tester.getSize(find.byType(HomeScreen)).width;
    expect(tester.getCenter(find.byTooltip('開始錄音')).dx, lessThan(width / 2));
    expect(tester.getCenter(find.byTooltip('匯入錄音檔')).dx, lessThan(width / 2));
    expect(find.textContaining('點左下角'), findsOneWidget, reason: 'the empty list points the right way');
  });

  testWidgets('one tap on the record button starts recording', (tester) async {
    await openWith(tester, Handedness.right);

    await tester.tap(find.byTooltip('開始錄音'));
    await settle(tester);

    expect(find.byType(LiveRecordScreen), findsOneWidget);
  });
}
