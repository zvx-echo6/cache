import 'dart:io';

import 'package:cache/platform/app_log.dart';
import 'package:cache/screens/settings/log_page.dart';
import 'package:cache/screens/settings/storage_page.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Storage > Advanced: background indexing speed, Gentle by default, Normal kept across restarts', (tester) async {
    final dir = Directory.systemTemp.createTempSync('indexing-speed');
    addTearDown(() => dir.deleteSync(recursive: true));
    final settings = AppSettings(settingsDirOverride: dir);
    await tester.runAsync(settings.init);
    expect(settings.indexingNormal, isFalse);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: IndexingSpeedPage(settings: settings)));
    expect(find.text('Background indexing speed'.toUpperCase()), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('indexing-gentle')), matching: find.byIcon(Icons.check)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('indexing-normal')));
    await tester.pump();
    expect(settings.indexingNormal, isTrue);
    expect(find.descendant(of: find.byKey(const ValueKey('indexing-normal')), matching: find.byIcon(Icons.check)), findsOneWidget);
    final again = AppSettings(settingsDirOverride: dir);
    await tester.runAsync(again.init);
    expect(again.indexingNormal, isTrue);
  });

  testWidgets('Settings > Log: the log level (Standard by default), Share log and Clear log', (tester) async {
    final dir = Directory.systemTemp.createTempSync('log-rows');
    addTearDown(() => dir.deleteSync(recursive: true));
    final settings = AppSettings(settingsDirOverride: dir);
    await tester.runAsync(settings.init);
    final log = AppLog(echo: (_) {});
    await tester.runAsync(() => log.open(Directory('${dir.path}/logs')));
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: LogPage(log: log)));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('log-clear')), 200);
    expect(find.text('Standard (default)'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('log-standard')), matching: find.byIcon(Icons.check)), findsOneWidget);
    expect(find.text('Share log'), findsOneWidget);
    expect(find.text('Clear log'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('log-detailed')));
    await tester.pump();
    expect(log.level, LogLevel.detailed);
    expect(find.descendant(of: find.byKey(const ValueKey('log-detailed')), matching: find.byIcon(Icons.check)), findsOneWidget);
  });
}
