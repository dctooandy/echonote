import 'package:flutter/material.dart';

/// The app's two palettes and its round look (spec feature-dark-theme):
/// cyan for anything tappable or emphasised, amber for "needs attention",
/// green for done, red only for recording, stopping and deleting.
class AppPalette {
  const AppPalette({
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.text,
    required this.textMuted,
    required this.line,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.amber,
    required this.amberSoft,
    required this.green,
    required this.greenSoft,
    required this.red,
    required this.redSoft,
    required this.onRed,
  });

  final Color background;
  final Color surface;
  final Color surfaceHigh;
  final Color text;
  final Color textMuted;
  final Color line;
  final Color accent;
  final Color onAccent;
  final Color accentSoft;
  final Color amber;
  final Color amberSoft;
  final Color green;
  final Color greenSoft;
  final Color red;
  final Color redSoft;
  final Color onRed;

  static const dark = AppPalette(
    background: Color(0xFF14171C),
    surface: Color(0xFF1D2129),
    surfaceHigh: Color(0xFF282D37),
    text: Color(0xFFE8EBF0),
    textMuted: Color(0xFF8D95A3),
    line: Color(0xFF2A2F39),
    accent: Color(0xFF6FD3E0),
    onAccent: Color(0xFF0D2A2E),
    accentSoft: Color(0xFF173A40),
    amber: Color(0xFFF2B84B),
    amberSoft: Color(0xFF3A2F17),
    green: Color(0xFF6AD69A),
    greenSoft: Color(0xFF173325),
    red: Color(0xFFFF6B6B),
    redSoft: Color(0xFF3D1C1E),
    onRed: Color(0xFF2A0B0B),
  );

  static const light = AppPalette(
    background: Color(0xFFF3F5F8),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFE6EAEF),
    text: Color(0xFF15191F),
    textMuted: Color(0xFF5D6573),
    line: Color(0xFFE1E5EA),
    accent: Color(0xFF0B7D8C),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFD6F0F3),
    amber: Color(0xFF9A5F00),
    amberSoft: Color(0xFFFCEFD3),
    green: Color(0xFF1D7F47),
    greenSoft: Color(0xFFDCF2E4),
    red: Color(0xFFD93A3A),
    redSoft: Color(0xFFFDE2E2),
    onRed: Color(0xFFFFFFFF),
  );
}

/// The colours a [ColorScheme] has no role for: amber, green and the soft
/// backgrounds behind status chips and round icons.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.amber,
    required this.amberSoft,
    required this.green,
    required this.greenSoft,
    required this.redSoft,
    required this.accentSoft,
  });

  AppColors.from(AppPalette p)
    : this(
        amber: p.amber,
        amberSoft: p.amberSoft,
        green: p.green,
        greenSoft: p.greenSoft,
        redSoft: p.redSoft,
        accentSoft: p.accentSoft,
      );

  final Color amber;
  final Color amberSoft;
  final Color green;
  final Color greenSoft;
  final Color redSoft;
  final Color accentSoft;

  /// Falls back to the dark palette where no app theme is installed (tests
  /// that build a bare MaterialApp).
  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>() ??
      AppColors.from(AppPalette.dark);

  @override
  AppColors copyWith({
    Color? amber,
    Color? amberSoft,
    Color? green,
    Color? greenSoft,
    Color? redSoft,
    Color? accentSoft,
  }) => AppColors(
    amber: amber ?? this.amber,
    amberSoft: amberSoft ?? this.amberSoft,
    green: green ?? this.green,
    greenSoft: greenSoft ?? this.greenSoft,
    redSoft: redSoft ?? this.redSoft,
    accentSoft: accentSoft ?? this.accentSoft,
  );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      amber: Color.lerp(amber, other.amber, t)!,
      amberSoft: Color.lerp(amberSoft, other.amberSoft, t)!,
      green: Color.lerp(green, other.green, t)!,
      greenSoft: Color.lerp(greenSoft, other.greenSoft, t)!,
      redSoft: Color.lerp(redSoft, other.redSoft, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
    );
  }
}

/// Corner radius of every card: whole blocks of text and list rows.
const kCardRadius = 20.0;

ThemeData buildAppTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.accent,
    onPrimary: p.onAccent,
    primaryContainer: p.accentSoft,
    onPrimaryContainer: p.accent,
    secondary: p.accent,
    onSecondary: p.onAccent,
    secondaryContainer: p.accentSoft,
    onSecondaryContainer: p.accent,
    tertiary: p.amber,
    onTertiary: p.background,
    tertiaryContainer: p.amberSoft,
    onTertiaryContainer: p.amber,
    error: p.red,
    onError: p.onRed,
    errorContainer: p.redSoft,
    onErrorContainer: p.red,
    surface: p.background,
    onSurface: p.text,
    onSurfaceVariant: p.textMuted,
    surfaceContainerLowest: p.background,
    surfaceContainerLow: p.surface,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.surfaceHigh,
    surfaceContainerHighest: p.surfaceHigh,
    outline: p.textMuted,
    outlineVariant: p.line,
    inverseSurface: p.text,
    onInverseSurface: p.background,
    inversePrimary: p.accent,
    shadow: Colors.black,
    scrim: Colors.black,
  );
  const stadium = StadiumBorder();
  final cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(kCardRadius),
  );

  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: p.background,
    extensions: [AppColors.from(p)],
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      foregroundColor: p.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: cardShape,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
    ),
    listTileTheme: ListTileThemeData(shape: cardShape),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: stadium),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: stadium,
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: stadium,
        side: BorderSide(color: p.line),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: stadium),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      shape: const CircleBorder(),
      backgroundColor: p.accent,
      foregroundColor: p.onAccent,
    ),
    chipTheme: ChipThemeData(
      shape: stadium,
      side: BorderSide.none,
      backgroundColor: p.surfaceHigh,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const CircleBorder(),
      side: BorderSide(color: p.textMuted, width: 2),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surfaceHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dividerTheme: DividerThemeData(color: p.line),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.background,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.accentSoft,
      height: 66,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? p.accent : p.textMuted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          color: states.contains(WidgetState.selected) ? p.text : p.textMuted,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : null,
        ),
      ),
    ),
  );
}
