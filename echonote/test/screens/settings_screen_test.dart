import 'dart:io';

import 'package:echonote/screens/settings_screen.dart';
import 'package:echonote/services/app_settings.dart';
import 'package:echonote/services/settings_store.dart';
import 'package:echonote/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late SettingsStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('settings_screen_test');
    store = SettingsStore(documentsDir: () async => dir);
  });

  tearDown(() => dir.delete(recursive: true));

  /// The app shell as main.dart builds it, opened on the settings page.
  Future<AppSettings> open(WidgetTester tester) async {
    final settings = (await tester.runAsync(() => AppSettings.load(store)))!;
    await tester.pumpWidget(
      AppSettingsScope(
        settings: settings,
        child: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => MaterialApp(
            theme: buildAppTheme(Brightness.light),
            darkTheme: buildAppTheme(Brightness.dark),
            themeMode: settings.themeMode,
            home: const SettingsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return settings;
  }

  /// Lets the real settings-file write finish between frames.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The chosen option is drawn in the on-accent colour.
  bool isChosen(WidgetTester tester, String label) {
    final scheme = Theme.of(tester.element(find.text(label))).colorScheme;
    return tester.widget<Text>(find.text(label)).style?.color == scheme.onPrimary;
  }

  Brightness brightness(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(SettingsScreen))).brightness;

  testWidgets('starts dark and right-handed', (tester) async {
    await open(tester);

    expect(brightness(tester), Brightness.dark);
    expect(isChosen(tester, '深色'), isTrue);
    expect(isChosen(tester, '淺色'), isFalse);
    expect(isChosen(tester, '右手'), isTrue);
    expect(isChosen(tester, '左手'), isFalse);
  });

  testWidgets('picking light restyles at once and is remembered', (tester) async {
    await open(tester);

    await tester.tap(find.text('淺色'));
    await settle(tester);

    expect(brightness(tester), Brightness.light);
    expect(isChosen(tester, '淺色'), isTrue);
    expect(await tester.runAsync(store.themeMode), ThemeMode.light);
  });

  testWidgets('picking left hand is remembered', (tester) async {
    final settings = await open(tester);

    await tester.tap(find.text('左手'));
    await settle(tester);

    expect(settings.handedness, Handedness.left);
    expect(await tester.runAsync(store.handedness), Handedness.left);
  });
}
