import 'package:flutter/material.dart';

import 'settings_store.dart';

export 'settings_store.dart' show Handedness;

/// The settings the whole app reacts to straight away: theme and
/// handedness (spec feature-dark-theme). Read once before the first frame,
/// so a light-theme user never sees a dark flash.
class AppSettings extends ChangeNotifier {
  AppSettings({
    this._store,
    this._themeMode = ThemeMode.dark,
    this._handedness = Handedness.right,
  });

  static Future<AppSettings> load(SettingsStore store) async => AppSettings(
    store: store,
    themeMode: await store.themeMode(),
    handedness: await store.handedness(),
  );

  /// Null keeps changes in memory only (tests).
  final SettingsStore? _store;
  ThemeMode _themeMode;
  Handedness _handedness;

  ThemeMode get themeMode => _themeMode;
  Handedness get handedness => _handedness;

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    notifyListeners();
    await _store?.setThemeMode(mode);
  }

  Future<void> setHandedness(Handedness hand) async {
    if (hand == _handedness) return;
    _handedness = hand;
    notifyListeners();
    await _store?.setHandedness(hand);
  }
}

/// Makes [AppSettings] available below it; widgets that read it rebuild
/// when a setting changes.
class AppSettingsScope extends InheritedNotifier<AppSettings> {
  const AppSettingsScope({
    super.key,
    required AppSettings settings,
    required super.child,
  }) : super(notifier: settings);

  /// Defaults (dark, right-handed) where no scope is installed, e.g. a test
  /// that pumps one screen on its own.
  static AppSettings of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AppSettingsScope>()
          ?.notifier ??
      _defaults;

  static final _defaults = AppSettings();
}
