import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'screens/home_screen.dart';
import 'services/analysis_service.dart';

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
