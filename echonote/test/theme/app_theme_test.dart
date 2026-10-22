import 'package:echonote/services/app_settings.dart';
import 'package:echonote/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dark theme uses the chosen palette (E)', () {
    final theme = buildAppTheme(Brightness.dark);
    final colors = theme.extension<AppColors>()!;

    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, const Color(0xFF14171C));
    expect(theme.colorScheme.primary, const Color(0xFF6FD3E0), reason: 'cyan: tappable, emphasis');
    expect(theme.colorScheme.error, const Color(0xFFFF6B6B), reason: 'red: record, stop, delete');
    expect(colors.amber, const Color(0xFFF2B84B));
    expect(colors.green, const Color(0xFF6AD69A));
  });

  test('light theme uses the deeper accents', () {
    final theme = buildAppTheme(Brightness.light);
    final colors = theme.extension<AppColors>()!;

    expect(theme.scaffoldBackgroundColor, const Color(0xFFF3F5F8));
    expect(theme.colorScheme.primary, const Color(0xFF0B7D8C));
    expect(theme.colorScheme.error, const Color(0xFFD93A3A));
    expect(colors.amber, const Color(0xFF9A5F00));
    expect(colors.green, const Color(0xFF1D7F47));
  });

  test('buttons, chips and checkboxes are round', () {
    final theme = buildAppTheme(Brightness.dark);

    expect(theme.filledButtonTheme.style!.shape!.resolve({}), isA<StadiumBorder>());
    expect(theme.chipTheme.shape, isA<StadiumBorder>());
    expect(theme.checkboxTheme.shape, isA<CircleBorder>());
    expect(
      (theme.cardTheme.shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(kCardRadius),
    );
  });

  testWidgets('changing the theme setting restyles the app at once', (tester) async {
    final settings = AppSettings();
    await tester.pumpWidget(
      AppSettingsScope(
        settings: settings,
        child: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => MaterialApp(
            theme: buildAppTheme(Brightness.light),
            darkTheme: buildAppTheme(Brightness.dark),
            themeMode: settings.themeMode,
            home: Builder(builder: (context) => Text('${Theme.of(context).brightness}')),
          ),
        ),
      ),
    );
    expect(find.text('${Brightness.dark}'), findsOneWidget);

    await settings.setThemeMode(ThemeMode.light);
    await tester.pumpAndSettle();

    expect(find.text('${Brightness.light}'), findsOneWidget);
  });
}
