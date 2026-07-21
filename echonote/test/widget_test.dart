import 'package:flutter_test/flutter_test.dart';

import 'package:echonote/main.dart';

void main() {
  testWidgets('Whisper POC screen shows initial controls', (WidgetTester tester) async {
    await tester.pumpWidget(const EchoNoteApp());

    expect(find.text('尚未選擇音檔'), findsOneWidget);
    expect(find.text('選擇音檔'), findsOneWidget);
    expect(find.text('開始轉錄'), findsOneWidget);
  });
}
