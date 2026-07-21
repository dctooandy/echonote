import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:echonote/main.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    return Directory.systemTemp.createTempSync('echonote_test').path;
  }
}

void main() {
  setUpAll(() {
    PathProviderPlatform.instance = _FakePathProviderPlatform();
  });

  testWidgets('App shows the home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const EchoNoteApp());
    await tester.pump();

    expect(find.text('echonote'), findsOneWidget);
  });
}
