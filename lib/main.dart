import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'services/asset_bundle_override.dart';
import 'services/model_download_manager.dart';
import 'ui/chat_page.dart';
import 'ui/theme.dart';

// Re-exported so `package:privai/main.dart` remains the entry point for tests
// and tooling that already reference ChatScreen from here.
export 'ui/chat_page.dart' show ChatScreen, ChatScreenState;

void main() {
  // Installs the binding that lets downloaded files stand in for bundled
  // assets, which is how the Kokoro voice table is delivered without adding
  // 52 MB to the app. Everything else loads from the real bundle as usual.
  AssetOverrideBinding.ensureInitialized();
  runApp(const MyApp());
  if (Platform.environment['FLUTTER_TEST'] != 'true') {
    unawaited(
      ModelDownloadManager()
          .initializeBackgroundDownloads()
          .catchError((error) {
        debugPrint('Background downloader initialization failed: $error');
      }),
    );
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  void _toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PrivAI',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode,
      home: ChatScreen(themeToggleCallback: _toggleTheme),
    );
  }
}
