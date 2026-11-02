import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:path_provider/path_provider.dart';

/// App preferences in `Documents/settings.json`. Small and non-critical: a
/// missing or unreadable file means defaults, and it's then overwritten.
class SettingsStore {
  SettingsStore({Future<Directory> Function()? documentsDir})
    : _documentsDir = documentsDir ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDir;

  static const _livePreviewKey = 'live_preview';
  static const _themeModeKey = 'theme_mode';
  static const _handednessKey = 'handedness';
  static const _homeViewKey = 'home_view';
  static const _myNameKey = 'my_name';

  Future<File> _file() async => File('${(await _documentsDir()).path}/settings.json');

  Future<Map<String, dynamic>> _read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return {};
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// Whether live text shows while recording. Off unless turned on: the
  /// preview is only a rough draft (spec feature-recording-indicator).
  Future<bool> livePreview() async {
    final value = (await _read())[_livePreviewKey];
    return value is bool ? value : false;
  }

  Future<void> setLivePreview(bool value) => _write(_livePreviewKey, value);

  /// Dark unless chosen otherwise (spec feature-dark-theme).
  Future<ThemeMode> themeMode() async =>
      _enumValue(ThemeMode.values, (await _read())[_themeModeKey], ThemeMode.dark);

  Future<void> setThemeMode(ThemeMode mode) => _write(_themeModeKey, mode.name);

  /// Which thumb the main buttons sit under; right unless chosen otherwise.
  Future<Handedness> handedness() async =>
      _enumValue(Handedness.values, (await _read())[_handednessKey], Handedness.right);

  Future<void> setHandedness(Handedness hand) => _write(_handednessKey, hand.name);

  /// The home list one meeting at a time, or grouped by series; single
  /// unless chosen otherwise (spec feature-chain-links, decision 3).
  Future<HomeView> homeView() async => _enumValue(HomeView.values, (await _read())[_homeViewKey], HomeView.single);

  Future<void> setHomeView(HomeView view) => _write(_homeViewKey, view.name);

  /// The user's own name, sent with meetings they took part in; null when
  /// not set (spec feature-my-name).
  Future<String?> myName() async {
    final value = (await _read())[_myNameKey];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  /// Null removes it.
  Future<void> setMyName(String? name) => _write(_myNameKey, name);

  static T _enumValue<T extends Enum>(List<T> values, Object? name, T fallback) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  /// Keeps any other settings already in the file; a null [value] removes
  /// [key].
  Future<void> _write(String key, Object? value) async {
    final settings = await _read();
    if (value == null) {
      settings.remove(key);
    } else {
      settings[key] = value;
    }
    await (await _file()).writeAsString(jsonEncode(settings));
  }
}

enum Handedness { right, left }

enum HomeView { single, series }
