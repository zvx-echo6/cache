import 'package:flutter/material.dart';

/// The host app for cache_ocr's integration tests (integration_test/ocr_test.dart); it shows nothing of its own.
/// The Android and iOS folders are made in CI by `flutter create --platforms=android,ios .`.
void main() => runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('cache_ocr')))));
