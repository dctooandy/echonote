import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'screens/home_screen.dart';
import 'services/analysis_service.dart';
import 'services/glossary_store.dart';

/// Temporary way to fill the glossary before the glossary screen exists
/// (spec task T4; remove with T5):
///   flutter run --dart-define=GLOSSARY_SEED=台積電、EchoNote、王小明
const _glossarySeed = String.fromEnvironment('GLOSSARY_SEED');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Firebase is only configured for iOS so far; elsewhere (Android) the app
  // still records and transcribes, and analysis reports itself unavailable.
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    AnalysisService.available = true;
  } on UnsupportedError catch (e) {
    debugPrint('Firebase not configured on this platform: ${e.message}');
  }
  if (_glossarySeed.isNotEmpty) await _seedGlossary();
  runApp(const EchoNoteApp());
}

class EchoNoteApp extends StatelessWidget {
  const EchoNoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'echonote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: const HomeScreen(),
    );
  }
}

Future<void> _seedGlossary() async {
  final store = GlossaryStore();
  try {
    for (final term in _glossarySeed.split('、')) {
      // Terms seeded on an earlier launch come back as duplicates.
      final error = await store.add(term);
      debugPrint('[Glossary seed] $term: ${error?.message ?? 'added'}');
    }
  } on GlossaryCorruptException catch (e) {
    debugPrint('[Glossary seed] $e');
  }
}
