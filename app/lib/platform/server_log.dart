import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../browse/web/device_api.dart' show kDeviceCallTimeout;
import 'app_log.dart' show AppLog, LogLevel, appLog;

/// In a browser: Cache Server's own app log (`/api/log`, signed in only): its level, its text for Share log, and Clear log. A browser
/// has no log file of its own, and this is never the server's system journal. The level is the server's, kept there.
class ServerLog extends ChangeNotifier {
  ServerLog({this.client, this.local});

  /// The browser app's own logger, which follows the server's level (so what the app logs in the console matches the level chosen
  /// here: Detailed prints messages and stacks, as on a phone). The app's own [appLog] by default.
  final AppLog? local;
  AppLog get _log => local ?? appLog;

  void _follow(LogLevel l) {
    if (_log.level != l) unawaited(_log.setLevel(l));
  }

  /// The HTTP client (tests give their own).
  final http.Client? client;
  http.Client get _c => client ?? http.Client();

  LogLevel level = LogLevel.standard;

  /// The log's size on the server (0: nothing logged yet).
  int bytes = 0;
  bool loaded = false;

  Future<Map?> _json(Future<http.Response> Function() call) async {
    try {
      final r = await call().timeout(kDeviceCallTimeout);
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      return j is Map && j['ok'] == true && j['result'] is Map ? j['result'] as Map : null;
    } catch (_) {
      return null;
    }
  }

  LogLevel? _level(Object? v) => LogLevel.values.where((l) => l.name == v).firstOrNull;

  /// Reads the level and the size.
  Future<void> refresh() async {
    final l = await _json(() => _c.get(Uri.parse('/api/log/level')));
    final t = await _json(() => _c.get(Uri.parse('/api/log')));
    level = _level(l?['level']) ?? level;
    if (l != null) _follow(level);
    bytes = (t?['bytes'] as num?)?.toInt() ?? bytes;
    loaded = l != null;
    notifyListeners();
  }

  /// Sets the server's level; false when it would not.
  Future<bool> setLevel(LogLevel l) async {
    final r = await _json(() => _c.put(Uri.parse('/api/log/level'), headers: {'content-type': 'application/json'}, body: jsonEncode({'level': l.name})));
    final got = _level(r?['level']);
    if (got == null) return false;
    level = got;
    _follow(got);
    notifyListeners();
    return true;
  }

  /// The log's text, or null when it could not be read.
  Future<String?> text() async => (await _json(() => _c.get(Uri.parse('/api/log'))))?['text'] as String?;

  /// Clears the server's log; false when it would not.
  Future<bool> clear() async {
    final r = await _json(() => _c.delete(Uri.parse('/api/log')));
    if (r == null) return false;
    await refresh();
    return true;
  }
}
