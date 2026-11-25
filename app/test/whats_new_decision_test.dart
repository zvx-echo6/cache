import 'dart:io';

import 'package:cache/theme.dart';
import 'package:cache/update/update_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _md = '## 1.2.0\n- **Travel:** modes.\n- Second.\n\n## 1.1.0\n- Old.\n';

void main() {
  late Directory dir;
  late List<String> logs;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('whats-new');
    logs = [];
    whatsNewAfterUpdate = true;
  });
  tearDown(() {
    whatsNewAfterUpdate = false;
    dir.deleteSync(recursive: true);
  });

  Future<BuildContext> host(WidgetTester t) async {
    late BuildContext ctx;
    await t.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: Builder(builder: (c) {
      ctx = c;
      return const Scaffold(body: Text('Home'));
    })));
    return ctx;
  }

  Future<void> run(WidgetTester t, BuildContext ctx, WhatsNewSeen seen, {required bool firstInstall, String version = '1.2.0'}) async {
    await t.runAsync(() async {
      unawaited2(maybeShowWhatsNew(ctx, seen: seen, firstInstall: firstInstall, version: version, read: () async => _md, log: logs.add));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
  }

  testWidgets('seen 1.1.0, model present: the sheet shows and 1.2.0 is recorded', (t) async {
    final seen = WhatsNewSeen(dirOverride: dir);
    await t.runAsync(() => seen.markSeen('1.1.0'));
    final ctx = await host(t);
    await run(t, ctx, seen, firstInstall: false);
    expect(find.textContaining("What's new"), findsWidgets);
    expect(find.textContaining('Second.'), findsOneWidget);
    expect(await t.runAsync(seen.lastSeen), '1.2.0');
    expect(logs.single, startsWith('whats-new: shown 1.2.0'));
  });

  testWidgets('seen 1.1.0, no model: the sheet still shows', (t) async {
    final seen = WhatsNewSeen(dirOverride: dir);
    await t.runAsync(() => seen.markSeen('1.1.0'));
    final ctx = await host(t);
    await run(t, ctx, seen, firstInstall: true);
    expect(find.textContaining('Second.'), findsOneWidget);
    expect(logs.single, startsWith('whats-new: shown 1.2.0'));
  });

  testWidgets('no record, model present: shows', (t) async {
    final seen = WhatsNewSeen(dirOverride: dir);
    final ctx = await host(t);
    await run(t, ctx, seen, firstInstall: false);
    expect(find.textContaining('Second.'), findsOneWidget);
    expect(logs.single, contains('seen none'));
  });

  testWidgets('no record and no model (true first install): silent, version recorded', (t) async {
    final seen = WhatsNewSeen(dirOverride: dir);
    final ctx = await host(t);
    await run(t, ctx, seen, firstInstall: true);
    expect(find.textContaining('Second.'), findsNothing);
    expect(await t.runAsync(seen.lastSeen), '1.2.0');
    expect(logs.single, 'whats-new: first install with no record, recorded 1.2.0');
  });

  testWidgets('seen equal: silent and logged', (t) async {
    final seen = WhatsNewSeen(dirOverride: dir);
    await t.runAsync(() => seen.markSeen('1.2.0'));
    final ctx = await host(t);
    await run(t, ctx, seen, firstInstall: false);
    expect(find.textContaining('Second.'), findsNothing);
    expect(logs.single, 'whats-new: seen equal (1.2.0)');
  });

  testWidgets('no section for the version: silent, logged, not recorded', (t) async {
    final seen = WhatsNewSeen(dirOverride: dir);
    await t.runAsync(() => seen.markSeen('1.1.0'));
    final ctx = await host(t);
    await run(t, ctx, seen, firstInstall: false, version: '1.9.9');
    expect(find.textContaining("What's new"), findsNothing);
    expect(logs.single, 'whats-new: no section for 1.9.9 (seen 1.1.0)');
    expect(await t.runAsync(seen.lastSeen), '1.1.0');
  });

  testWidgets('test flag off: silent, logged', (t) async {
    whatsNewAfterUpdate = false;
    final seen = WhatsNewSeen(dirOverride: dir);
    final ctx = await host(t);
    await run(t, ctx, seen, firstInstall: false);
    expect(find.textContaining('Second.'), findsNothing);
    expect(logs.single, startsWith('whats-new: off'));
  });

  test('guard names what is in the way, or null on Home', () {
    expect(whatsNewGuard(moduleOpen: true, onModules: false, homeIsCurrent: true), 'a module is open');
    expect(whatsNewGuard(moduleOpen: false, onModules: true, homeIsCurrent: true), 'on the modules page');
    expect(whatsNewGuard(moduleOpen: false, onModules: false, homeIsCurrent: false), 'Home is not the current route');
    expect(whatsNewGuard(moduleOpen: false, onModules: false, homeIsCurrent: true), isNull);
  });

  test('whenStarted waits for the models folder to be read (the shell asks before that)', () async {
    final app = ChangeNotifier();
    var started = false;
    var done = false;
    final f = whenStarted(app, () => started).then((_) => done = true);
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse);
    // ignore: invalid_use_of_protected_member
    app.notifyListeners();
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse);
    started = true;
    // ignore: invalid_use_of_protected_member
    app.notifyListeners();
    await f;
    expect(done, isTrue);
    await whenStarted(app, () => true);
  });

  test('the shipped whats_new.md has a 1.2.0 section matching kAppVersion', () {
    final lines = whatsNewLines(File('assets/whats_new.md').readAsStringSync(), '1.2.0');
    expect(lines.length, 10);
  });
}

void unawaited2(Future<void> f) {}
