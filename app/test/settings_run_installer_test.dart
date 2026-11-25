// Cache on Linux: "Cache can't open your folders. Run the installer again to fix this." at the top of Settings while Cache runs as
// the fallback cache account instead of the person who installed it (the server says so in GET /api/version, run_installer_again).
// "How" shows the commands. A phone never shows it.

import 'dart:convert';

import 'package:cache/browse/web/device_api.dart';
import 'package:cache/linux_ui.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/settings_rig.dart';

const _line = "Cache can't open your folders. Run the installer again to fix this.";

void main() {
  tearDown(() => debugLinuxUi = null);

  group('readRunInstallerAgain', () {
    test('reads run_installer_again from /api/version', () async {
      Uri? asked;
      final client = MockClient((r) async {
        asked = r.url;
        return http.Response(jsonEncode({'ok': true, 'result': {'version': '0.1.0+1c6891f', 'run_installer_again': true}}), 200);
      });
      expect(await readRunInstallerAgain(client: client), isTrue);
      expect(asked?.path, '/api/version');
    });

    test('false when the server says false, says nothing (an older server), or cannot be read', () async {
      Future<bool> answer(Object body, [int status = 200]) =>
          readRunInstallerAgain(client: MockClient((r) async => http.Response(body is String ? body : jsonEncode(body), status)));
      expect(await answer({'ok': true, 'result': {'version': '0.1.0', 'run_installer_again': false}}), isFalse);
      expect(await answer({'ok': true, 'result': {'version': '0.1.0'}}), isFalse);
      expect(await answer('{}', 404), isFalse);
      expect(await answer('nope'), isFalse);
      expect(await readRunInstallerAgain(client: MockClient((r) async => throw Exception('down'))), isFalse);
    });
  });

  group('the Run the installer again card in Settings', () {
    testWidgets('shows at the top of the list with the exact words when the server says so', (tester) async {
      debugLinuxUi = true;
      final r = await SettingsRig.create(tester);
      await r.show(tester, SettingsScreen(deps: r.deps, runInstallerAgain: () async => true));
      await tester.pump();
      expect(find.text(_line), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-run-installer')), findsOneWidget);
      final icon = tester.widget<Icon>(find.descendant(of: find.byKey(const ValueKey('settings-run-installer')), matching: find.byIcon(Icons.folder_off_outlined)));
      expect(icon.color, isNotNull);
      expect(find.text('How'), findsOneWidget);
      // above every other row
      expect(tester.getTopLeft(find.text(_line)).dy, lessThan(tester.getTopLeft(find.text('Cache model and web search')).dy));
      // no dismiss
      expect(find.byIcon(Icons.close), findsNothing);
      await r.dispose(tester);
    });

    testWidgets('absent when the server says no', (tester) async {
      debugLinuxUi = true;
      final r = await SettingsRig.create(tester);
      await r.show(tester, SettingsScreen(deps: r.deps, runInstallerAgain: () async => false));
      await tester.pump();
      expect(find.text(_line), findsNothing);
      expect(find.byKey(const ValueKey('settings-run-installer')), findsNothing);
      expect(find.text('Cache model and web search'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('How opens the dialog with the commands to run', (tester) async {
      debugLinuxUi = true;
      final r = await SettingsRig.create(tester);
      await r.show(tester, SettingsScreen(deps: r.deps, runInstallerAgain: () async => true));
      await tester.pump();
      await tester.tap(find.text('How'));
      await tester.pumpAndSettle();
      final dialog = find.byKey(const ValueKey('how-to-run-installer'));
      expect(dialog, findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text('Run the installer again')), findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text('tar -xzf cache-*.tar.gz ./install.sh\nsudo sh install.sh cache-*.tar.gz')), findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.textContaining('server')), findsNothing, reason: "it's their computer");
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(find.text(_line), findsOneWidget, reason: 'the card stays until Cache starts as the person');
      await r.dispose(tester);
    });

    testWidgets('a phone never shows it, and never asks', (tester) async {
      debugLinuxUi = false;
      var asked = 0;
      final r = await SettingsRig.create(tester);
      await r.show(tester, SettingsScreen(deps: r.deps, runInstallerAgain: () async {
        asked++;
        return true;
      }));
      await tester.pump();
      expect(find.text(_line), findsNothing);
      expect(find.byKey(const ValueKey('settings-run-installer')), findsNothing);
      expect(asked, 0);
      await r.dispose(tester);
    });
  });
}
