// Settings > Storage > Advanced in the browser: the log level, Share log and Clear log work on Cache Server's own log (/api/log).

import 'dart:convert';

import 'package:cache/linux_ui.dart';
import 'package:cache/platform/app_log.dart';
import 'package:cache/platform/server_log.dart';
import 'package:cache/screens/settings/storage_page.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/platform/share_or_copy.dart' show saveFileInBrowser, systemShareAvailable;
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'dart:io';

class _Fake extends ServerLog {
  String logText = '2026-11-17T00:00:00Z ERROR something failed';
  int clears = 0;

  @override
  Future<String?> text() async => logText;

  @override
  Future<bool> clear() async {
    clears++;
    logText = '';
    bytes = 0;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> setLevel(LogLevel l) async {
    level = l;
    notifyListeners();
    return true;
  }

  @override
  Future<void> refresh() async {
    bytes = logText.length;
    loaded = true;
    notifyListeners();
  }
}

void main() {
  test('ServerLog reads and sets the level, reads the text and clears, all through /api/log', () async {
    final seen = <String>[];
    final client = MockClient((r) async {
      seen.add('${r.method} ${r.url.path}');
      final result = switch ('${r.method} ${r.url.path}') {
        'GET /api/log/level' => {'level': 'detailed'},
        'PUT /api/log/level' => {'level': (jsonDecode(r.body) as Map)['level']},
        'GET /api/log' => {'text': 'a line\n', 'bytes': 7},
        _ => {'cleared': true},
      };
      return http.Response(jsonEncode({'ok': true, 'result': result}), 200);
    });
    final log = ServerLog(client: client);
    await log.refresh();
    expect((log.level, log.bytes, log.loaded), (LogLevel.detailed, 7, true));
    expect(await log.setLevel(LogLevel.minimal), isTrue);
    expect(log.level, LogLevel.minimal);
    expect(await log.text(), 'a line\n');
    expect(await log.clear(), isTrue);
    expect(seen, contains('DELETE /api/log'));
    expect(await ServerLog(client: MockClient((r) async => http.Response('{}', 401))).setLevel(LogLevel.standard), isFalse);
    expect(await ServerLog(client: MockClient((r) async => throw Exception('down'))).text(), isNull);
  });

  testWidgets('in the browser the Advanced log rows use the server log: level, Share log (copy or download) and Clear log', (tester) async {
    debugLinuxUi = true;
    addTearDown(() => debugLinuxUi = null);
    final dir = Directory.systemTemp.createTempSync('server-log-rows');
    addTearDown(() => dir.deleteSync(recursive: true));
    final settings = AppSettings(settingsDirOverride: dir);
    await tester.runAsync(settings.init);
    final server = _Fake();
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: IndexingSpeedPage(settings: settings, serverLog: server)));
    await tester.pump();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('log-clear')), 200);
    expect(find.text('Share log'), findsOneWidget);
    expect(find.text('Clear log'), findsOneWidget);
    // the level goes to the server
    await tester.tap(find.byKey(const ValueKey('log-detailed')));
    await tester.pump();
    expect(server.level, LogLevel.detailed);
    expect(find.descendant(of: find.byKey(const ValueKey('log-detailed')), matching: find.byIcon(Icons.check)), findsOneWidget);
    // Share log opens the Copy / Download sheet; Download saves the server's text with the browser's own save
    final oldShare = systemShareAvailable;
    final oldSave = saveFileInBrowser;
    systemShareAvailable = () => false;
    String? savedName;
    String? savedText;
    saveFileInBrowser = (name, mime, bytes) {
      savedName = name;
      savedText = utf8.decode(bytes);
    };
    addTearDown(() {
      systemShareAvailable = oldShare;
      saveFileInBrowser = oldSave;
    });
    await tester.tap(find.byKey(const ValueKey('log-share')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('web-share-download')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('web-share-download')));
    await tester.pumpAndSettle();
    expect(savedText, '2026-11-17T00:00:00Z ERROR something failed');
    expect(savedName, endsWith('.md'));
    // Clear log clears the server's, and Share log then has nothing to share
    await tester.tap(find.byKey(const ValueKey('log-clear')));
    await tester.pumpAndSettle();
    expect(server.clears, 1);
    expect(find.text('Log cleared'), findsOneWidget);
    expect(find.text('No log yet'), findsOneWidget);
  });
}
