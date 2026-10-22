import 'dart:convert';
import 'dart:io';

import 'package:echonote/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
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

  testWidgets('each entry shows its length after the date, when known', (tester) async {
    writeEntry('1', durationMs: 44 * 60000 + 12000);
    writeEntry('2', durationMs: 3600000 + 5 * 60000 + 30000);
    writeEntry('3');

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await settle(tester);

    expect(find.text('2026-10-22 14:30:05 · 44:12'), findsOneWidget);
    expect(find.text('2026-10-22 14:30:05 · 1:05:30'), findsOneWidget);
    expect(find.text('2026-10-22 14:30:05'), findsOneWidget, reason: 'no length yet: date only');
  });
}
