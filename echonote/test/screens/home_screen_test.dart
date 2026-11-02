import 'dart:convert';
import 'dart:io';

import 'package:echonote/screens/home_screen.dart';
import 'package:echonote/screens/live_record_screen.dart';
import 'package:echonote/services/app_settings.dart';
import 'package:echonote/services/settings_store.dart';
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

  void writeEntry(String id, {int? durationMs, String createdAt = '2026-10-22T14:30:05.000', String? previous, String? seriesName}) {
    final history = Directory('${dir.path}/history')..createSync(recursive: true);
    File('${history.path}/$id.json').writeAsStringSync(jsonEncode({
      'id': id,
      'audio_name': '錄音 $id',
      'created_at': createdAt,
      'audio_file_name': '$id.wav',
      'segments': [],
      'duration_ms': ?durationMs,
      'previous_recording_id': ?previous,
      'series_name': ?seriesName,
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

  testWidgets('import is a labelled pill above the record button', (tester) async {
    await openWith(tester, Handedness.right);

    expect(find.widgetWithText(OutlinedButton, '匯入'), findsOneWidget);
    expect(
      tester.getCenter(find.byTooltip('匯入錄音檔')).dy,
      lessThan(tester.getCenter(find.byTooltip('開始錄音')).dy),
    );
  });

  testWidgets('one tap on the record button starts recording', (tester) async {
    await openWith(tester, Handedness.right);

    await tester.tap(find.byTooltip('開始錄音'));
    await settle(tester);

    expect(find.byType(LiveRecordScreen), findsOneWidget);
  });

  group('single and series views (spec feature-chain-links)', () {
    // w1 <- w2 <- w3, w2 <- kick; t1 <- t2; solo alone.
    void writeLinked() {
      writeEntry('w1', createdAt: '2026-10-31T16:52:00.000');
      writeEntry('w2', createdAt: '2026-11-01T14:05:00.000', previous: 'w1');
      writeEntry('kick', createdAt: '2026-11-03T10:30:00.000', previous: 'w2');
      writeEntry('w3', createdAt: '2026-11-08T14:00:00.000', previous: 'w2');
      writeEntry('t1', createdAt: '2026-10-20T11:00:00.000');
      writeEntry('t2', createdAt: '2026-11-01T12:33:00.000', previous: 't1');
      writeEntry('solo', createdAt: '2026-11-01T13:11:00.000');
    }

    Future<AppSettings> open(WidgetTester tester, {HomeView view = HomeView.single}) async {
      // Tall enough that every row is built.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final settings = AppSettings(store: SettingsStore(documentsDir: () async => dir), homeView: view);
      await tester.pumpWidget(
        AppSettingsScope(
          settings: settings,
          child: MaterialApp(home: HomeScreen(durationProbe: _FakeProbe({}))),
        ),
      );
      await settle(tester);
      await settle(tester); // seven files to read
      return settings;
    }

    testWidgets('the single view lists every meeting and says how they link', (tester) async {
      writeLinked();
      await open(tester);

      expect(find.text('錄音 solo'), findsOneWidget);
      expect(find.text('接續 10/31'), findsOneWidget);
      expect(find.text('2 場後續'), findsOneWidget);
      expect(find.text('1 場後續'), findsNWidgets(2));
      expect(find.text('接續 11/1'), findsNWidgets(2));
      expect(find.text('接續 10/20'), findsOneWidget);
      expect(find.byIcon(Icons.subdirectory_arrow_left), findsNWidgets(4));
      // Each hint in its series' color: website and trip differ.
      Color colorOf(String text) => tester.widget<Text>(find.text(text)).style!.color!;
      expect(colorOf('接續 10/31'), colorOf('2 場後續'));
      expect(colorOf('接續 10/31'), isNot(colorOf('接續 10/20')));
    });

    testWidgets('the series view groups linked meetings, hides lone ones, and is remembered', (tester) async {
      writeLinked();
      final settings = await open(tester);

      await tester.tap(find.text('系列'));
      await settle(tester);

      expect(settings.homeView, HomeView.series);
      expect(find.text('錄音 solo'), findsNothing);
      expect(find.text('4 場 · 最近 11/8'), findsOneWidget);
      expect(find.text('2 場 · 最近 11/1'), findsOneWidget);
      expect(find.text('另有 1 場沒有接續，在「全部」裡'), findsOneWidget);
      // The newest series on top; the branch says what it follows.
      expect(tester.getTopLeft(find.text('4 場 · 最近 11/8')).dy, lessThan(tester.getTopLeft(find.text('2 場 · 最近 11/1')).dy));
      expect(find.text('接續 11/1'), findsOneWidget);

      final stored = jsonDecode(File('${dir.path}/settings.json').readAsStringSync()) as Map<String, dynamic>;
      expect(stored['home_view'], 'series');
    });

    testWidgets('全部 groups cards by day, each with its time on the left and no status icon', (tester) async {
      writeLinked();
      await open(tester);

      final now = DateTime.now().year;
      String heading(String day) => now == 2026 ? day : '2026年$day';
      for (final day in ['11月8日（日）', '11月3日（二）', '11月1日（日）', '10月31日（六）', '10月20日（二）']) {
        expect(find.text(heading(day)), findsOneWidget, reason: day);
      }
      // Three meetings on 11/1 under one heading.
      expect(tester.getTopLeft(find.text(heading('11月1日（日）'))).dy, lessThan(tester.getTopLeft(find.text('14:05')).dy));
      expect(tester.getTopLeft(find.text('14:05')).dy, lessThan(tester.getTopLeft(find.text('12:33')).dy));
      expect(tester.getTopLeft(find.text('14:05')).dx, lessThan(tester.getTopLeft(find.text('錄音 w2')).dx));
      expect(find.byType(CircleAvatar), findsNothing);
    });

    testWidgets('a long press names the series, kept on its first meeting; clearing it goes back', (tester) async {
      writeLinked();
      await open(tester, view: HomeView.series);
      expect(find.text('錄音 w3'), findsNWidgets(2), reason: 'named after the latest meeting, which is also a row');

      await tester.longPress(find.text('4 場 · 最近 11/8'));
      await tester.pumpAndSettle();
      expect(find.text('系列名稱'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '  官網改版  ');
      await tester.tap(find.text('儲存'));
      await settle(tester);
      await settle(tester);

      expect(find.text('官網改版'), findsOneWidget);
      expect(saved('w1')['series_name'], '官網改版');
      expect(saved('w3').containsKey('series_name'), isFalse);

      await tester.longPress(find.text('官網改版'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.text('儲存'));
      await settle(tester);
      await settle(tester);
      expect(find.text('錄音 w3'), findsNWidgets(2));
      expect(saved('w1').containsKey('series_name'), isFalse);
    });

    testWidgets('a long press on any card renames that meeting, in both views', (tester) async {
      writeLinked();
      await open(tester);

      await tester.longPress(find.text('錄音 solo'));
      await tester.pumpAndSettle();
      expect(find.text('會議名稱'), findsOneWidget);
      expect(find.text('清空就恢復成：錄音 solo'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '技術選型');
      await tester.tap(find.text('儲存'));
      await settle(tester);
      await settle(tester);
      expect(find.text('技術選型'), findsOneWidget);
      expect(saved('solo')['custom_title'], '技術選型');

      await tester.tap(find.text('系列'));
      await settle(tester);
      await tester.longPress(find.text('錄音 t1'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '旅遊初談');
      await tester.tap(find.text('儲存'));
      await settle(tester);
      await settle(tester);
      expect(find.text('旅遊初談'), findsOneWidget);
      expect(saved('t1')['custom_title'], '旅遊初談');
    });

    testWidgets('the series view without any links says how to make one', (tester) async {
      writeEntry('solo');
      await open(tester, view: HomeView.series);
      expect(find.textContaining('還沒有接續的會議'), findsOneWidget);
    });
  });

  testWidgets('the view tabs sit on the thumb side', (tester) async {
    writeEntry('1');
    Future<double> tabsX(Handedness hand) async {
      await tester.pumpWidget(
        AppSettingsScope(
          settings: AppSettings(handedness: hand),
          child: MaterialApp(home: HomeScreen(durationProbe: _FakeProbe({}))),
        ),
      );
      await settle(tester);
      return tester.getCenter(find.text('系列')).dx;
    }

    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(await tabsX(Handedness.right), greaterThan(width / 2));
    expect(await tabsX(Handedness.left), lessThan(width / 2));
    expect(find.text('全部'), findsOneWidget);
  });
}
