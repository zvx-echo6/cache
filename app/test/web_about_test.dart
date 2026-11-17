// The browser's Credits and licenses page names the server's version beside the app's, read from GET /api/version.

import 'dart:convert';

import 'package:cache/browse/web/device_api.dart';
import 'package:cache/linux_ui.dart';
import 'package:cache/screens/settings/about_pages.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  tearDown(() => debugLinuxUi = null);

  group('readServerVersion', () {
    test('reads the version from /api/version', () async {
      Uri? asked;
      final client = MockClient((r) async {
        asked = r.url;
        return http.Response(jsonEncode({'ok': true, 'result': {'version': '0.1.0+1c6891f'}}), 200);
      });
      expect(await readServerVersion(client: client), '0.1.0+1c6891f');
      expect(asked?.path, '/api/version');
    });

    test('an answer that is not a version, or a failure, is null', () async {
      expect(await readServerVersion(client: MockClient((r) async => http.Response('{}', 404))), isNull);
      expect(await readServerVersion(client: MockClient((r) async => http.Response('nope', 200))), isNull);
      expect(await readServerVersion(client: MockClient((r) async => throw Exception('down'))), isNull);
    });
  });

  group('Credits and licenses in the browser', () {
    Future<void> show(WidgetTester tester, Widget page) async {
      tester.view.physicalSize = const Size(1440, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: page));
      await tester.pumpAndSettle();
    }

    testWidgets('the app version and the server version are both shown', (tester) async {
      debugLinuxUi = true;
      await show(tester, AboutPage(version: () async => '1.1.0', serverVersion: () async => '0.1.0+1c6891f'));
      expect(find.text('Version'), findsOneWidget);
      expect(find.text('1.1.0'), findsOneWidget);
      expect(find.text('Server version'), findsOneWidget);
      expect(find.text('0.1.0+1c6891f'), findsOneWidget);
    });

    testWidgets('a phone has no server version row', (tester) async {
      debugLinuxUi = false;
      await show(tester, AboutPage(version: () async => '1.1.0', serverVersion: () async => '0.1.0+1c6891f'));
      expect(find.text('Server version'), findsNothing);
    });
  });
}
