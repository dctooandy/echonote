import 'dart:convert';
import 'dart:io';

import 'package:echonote/services/settings_store.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late SettingsStore store;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('settings_test');
    store = SettingsStore(documentsDir: () async => dir);
    file = File('${dir.path}/settings.json');
  });

  tearDown(() => dir.delete(recursive: true));

  test('live preview is off when nothing is saved', () async {
    expect(await store.livePreview(), isFalse);
  });

  test('the choice is remembered', () async {
    await store.setLivePreview(true);
    expect(await store.livePreview(), isTrue);

    await store.setLivePreview(false);
    expect(await store.livePreview(), isFalse);
  });

  test('an unreadable file means defaults, and is replaced on the next save', () async {
    await file.writeAsString('{not json');

    expect(await store.livePreview(), isFalse);
    await store.setLivePreview(true);
    expect(await store.livePreview(), isTrue);
  });

  test('a wrongly typed value means the default', () async {
    await file.writeAsString(jsonEncode({'live_preview': 'yes'}));

    expect(await store.livePreview(), isFalse);
  });

  test('saving keeps settings it does not know about', () async {
    await file.writeAsString(jsonEncode({'theme': 'dark'}));

    await store.setLivePreview(true);

    expect(jsonDecode(await file.readAsString()), {'theme': 'dark', 'live_preview': true});
  });

  test('theme is dark and hand is right when nothing is saved', () async {
    expect(await store.themeMode(), ThemeMode.dark);
    expect(await store.handedness(), Handedness.right);
  });

  test('theme and hand are remembered', () async {
    await store.setThemeMode(ThemeMode.system);
    await store.setHandedness(Handedness.left);

    expect(await store.themeMode(), ThemeMode.system);
    expect(await store.handedness(), Handedness.left);
    expect(jsonDecode(await file.readAsString()), {'theme_mode': 'system', 'handedness': 'left'});
  });

  test('unknown theme or hand values mean the defaults', () async {
    await file.writeAsString(jsonEncode({'theme_mode': 'sepia', 'handedness': 3}));

    expect(await store.themeMode(), ThemeMode.dark);
    expect(await store.handedness(), Handedness.right);
  });

  test('each setting keeps the others', () async {
    await store.setLivePreview(true);
    await store.setThemeMode(ThemeMode.light);
    await store.setHandedness(Handedness.left);

    expect(await store.livePreview(), isTrue);
    expect(await store.themeMode(), ThemeMode.light);
  });

  test('my name is unset until saved, and null removes it', () async {
    expect(await store.myName(), isNull);
    await store.setMyName('Andy');
    expect(await store.myName(), 'Andy');
    await store.setMyName(null);
    expect(await store.myName(), isNull);
    expect((jsonDecode(await file.readAsString()) as Map).containsKey('my_name'), isFalse);
  });

  test('a blank saved name counts as unset', () async {
    await file.writeAsString(jsonEncode({'my_name': '  '}));
    expect(await store.myName(), isNull);
  });

  test('the LINE greeting name is unset until saved', () async {
    expect(await store.lineGreetingName(), isNull);
    await store.setLineGreetingName('陳醫師');
    expect(await store.lineGreetingName(), '陳醫師');
    await store.setLineGreetingName(null);
    expect(await store.lineGreetingName(), isNull);
  });
}
