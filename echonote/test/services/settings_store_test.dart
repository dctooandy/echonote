import 'dart:convert';
import 'dart:io';

import 'package:echonote/services/settings_store.dart';
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
}
