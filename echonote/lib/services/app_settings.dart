import 'package:flutter/material.dart';

import 'settings_store.dart';

export 'settings_store.dart' show Handedness, HomeView;

/// The settings the whole app reacts to straight away: theme and
/// handedness (spec feature-dark-theme). Read once before the first frame,
/// so a light-theme user never sees a dark flash.
class AppSettings extends ChangeNotifier {
  AppSettings({
    this._store,
    this._themeMode = ThemeMode.dark,
    this._handedness = Handedness.right,
    this._homeView = HomeView.single,
    this._myName,
    this._lineGreetingName,
  });

  static Future<AppSettings> load(SettingsStore store) async => AppSettings(
    store: store,
    themeMode: await store.themeMode(),
    handedness: await store.handedness(),
    homeView: await store.homeView(),
    myName: await store.myName(),
    lineGreetingName: await store.lineGreetingName(),
  );

  /// Null keeps changes in memory only (tests).
  final SettingsStore? _store;
  ThemeMode _themeMode;
  Handedness _handedness;
  HomeView _homeView;
  String? _myName;
  String? _lineGreetingName;

  ThemeMode get themeMode => _themeMode;
  Handedness get handedness => _handedness;
  HomeView get homeView => _homeView;

  /// The user's own name; null when not set (spec feature-my-name).
  String? get myName => _myName;

  /// Who the last LINE message greeted; null when none.
  String? get lineGreetingName => _lineGreetingName;

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

  Future<void> setHomeView(HomeView view) async {
    if (view == _homeView) return;
    _homeView = view;
    notifyListeners();
    await _store?.setHomeView(view);
  }

  /// Sets the name from what was typed: trimmed, cut to [myNameMaxChars];
  /// blank clears it. Throws when it can't be saved, leaving it unchanged.
  Future<void> setMyName(String typed) async {
    final name = String.fromCharCodes(typed.trim().runes.take(myNameMaxChars)).trim();
    final value = name.isEmpty ? null : name;
    if (value == _myName) return;
    await _store?.setMyName(value);
    _myName = value;
    notifyListeners();
  }

  Future<void> setLineGreetingName(String typed) async {
    final name = typed.trim();
    final value = name.isEmpty ? null : name;
    if (value == _lineGreetingName) return;
    await _store?.setLineGreetingName(value);
    _lineGreetingName = value;
  }
}

/// The longest name the user can give themselves; matches the function's
/// `MY_NAME_MAX_CHARS` (spec feature-my-name, decision 2).
const myNameMaxChars = 20;

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
