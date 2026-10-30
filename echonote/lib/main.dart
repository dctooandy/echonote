import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'screens/home_screen.dart';
import 'services/analysis_service.dart';
import 'services/app_settings.dart';
import 'services/settings_store.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Firebase is only configured for iOS so far; elsewhere (Android) the app
  // still records and transcribes, and analysis reports itself unavailable.
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    // Only a free Personal Team signs the app, so App Attest is out: every
    // build uses the debug provider with a token registered in the Firebase
    // console (spec feature-app-check, decision 18). Without the define the
    // SDK generates its own token and prints it to the Xcode console.
    const debugToken = String.fromEnvironment('APP_CHECK_DEBUG_TOKEN');
    await FirebaseAppCheck.instance.activate(
      providerApple: AppleDebugProvider(debugToken: debugToken.isEmpty ? null : debugToken),
    );
    AnalysisService.available = true;
  } on UnsupportedError catch (e) {
    debugPrint('Firebase not configured on this platform: ${e.message}');
  }
  runApp(EchoNoteApp(settings: await AppSettings.load(SettingsStore())));
}

class EchoNoteApp extends StatelessWidget {
  EchoNoteApp({super.key, AppSettings? settings}) : settings = settings ?? AppSettings();

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return AppSettingsScope(
      settings: settings,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => MaterialApp(
          title: 'echonote',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(Brightness.light),
          darkTheme: buildAppTheme(Brightness.dark),
          themeMode: settings.themeMode,
          home: const HomeScreen(),
        ),
      ),
    );
  }
}
