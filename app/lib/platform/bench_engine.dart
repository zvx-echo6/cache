import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('cache/bench');

/// The engine settings a test APK was launched with (the intent extra "cache_engine", a JSON object; see MainActivity.kt), or
/// null: always null in a release build, where the Android side never reads the intent.
Future<Map<String, dynamic>?> benchEngineConfig() async {
  if (!Platform.isAndroid) return null;
  try {
    return parseBenchEngine(await _channel.invokeMethod<String>('engineConfig'));
  } catch (_) {
    return null;
  }
}

/// The JSON text of the intent extra as an object, or null when there is none or it is not a JSON object.
Map<String, dynamic>? parseBenchEngine(String? text) {
  if (text == null || text.trim().isEmpty) return null;
  try {
    final v = jsonDecode(text);
    return v is Map ? v.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}
