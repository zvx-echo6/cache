import 'package:flutter/material.dart';

import 'selftest.dart';

/// The host app for cache_ocr's integration tests (integration_test/ocr_test.dart); it shows nothing of its own.
/// The Android and iOS folders are made in CI by `flutter create --platforms=android,ios .`.
///
/// Built with --dart-define=OCR_SELFTEST=1 it reads the bundled page images through the device engine at start and prints
/// OCR-RESULT (a RELEASE build cannot run `flutter test`; .github/workflows/ocr-release.yml uses this).
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (const String.fromEnvironment('OCR_SELFTEST').isNotEmpty) runOcrSelfTest(); // a String: bool.fromEnvironment reads only "true", not "1"
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('cache_ocr')))));
}
