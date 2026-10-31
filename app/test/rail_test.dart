import 'dart:io';

import 'package:cache/layout/adaptive.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/settings_rig.dart';

void main() {
  late SettingsRig r;
  late LayoutState layout;
  late NavState nav;
  late Directory dir;

  void size(WidgetTester tester, Size s) {
    tester.view.physicalSize = s * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> shell(WidgetTester tester, Size s) async {
    size(tester, s);
    await tester.pumpWidget(MaterialApp(
      key: UniqueKey(),
      theme: buildTheme(CacheThemeId.light),
      home: Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub, railPrefs: RailPrefs(dirOverride: dir)),
    ));
    await settle(tester);
  }

  Future<void> setUpRig(WidgetTester tester) async {
    r = await SettingsRig.create(tester);
    dir = Directory.systemTemp.createTempSync('rail');
    PanePrefs.testDir = dir;
    addTearDown(() => PanePrefs.testDir = null);
    layout = LayoutState(settingsDirOverride: dir);
    await tester.runAsync(layout.init);
    nav = NavState(backend: FakeBackend(), location: r.location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
  }

  Future<void> tearDownRig(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    layout.dispose();
    await r.dispose(tester);
  }

  testWidgets('a tablet held upright has the bottom bar, as on a phone, and no rail', (tester) async {
    await setUpRig(tester);
    await shell(tester, const Size(820, 1180));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-rail')), findsNothing);
    await tearDownRig(tester);
  });

  testWidgets('sideways: Hide menu slides the rail away, Show menu brings it back, and the choice is kept on this device', (tester) async {
    await setUpRig(tester);
    await shell(tester, const Size(1180, 820));
    expect(find.byKey(const ValueKey('nav-rail')), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byKey(const ValueKey('rail-hide')));
    await tester.pump(const Duration(milliseconds: 100));
    final mid = tester.getTopRight(find.byKey(const ValueKey('nav-rail'))).dx;
    await tester.pumpAndSettle();
    expect(mid, greaterThan(0.5), reason: 'it slides (animated), it does not jump');
    expect(tester.getTopRight(find.byKey(const ValueKey('nav-rail'))).dx, lessThanOrEqualTo(0.5));
    expect(find.byTooltip('Show menu'), findsOneWidget, reason: 'the way back, also for a screen reader');
    expect(File('${dir.path}/rail.json').readAsStringSync(), '{"hidden":true}');
    await shell(tester, const Size(1180, 820));
    expect(find.byTooltip('Show menu'), findsOneWidget, reason: 'kept after a restart');
    await tester.tap(find.byKey(const ValueKey('rail-show')));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('nav-rail'))).width, greaterThanOrEqualTo(kRailWidth));
    expect(File('${dir.path}/rail.json').readAsStringSync(), '{"hidden":false}');
    await tearDownRig(tester);
  });

  testWidgets('a two-pane list hides with Hide list, comes back with Show <list> in the detail\'s top bar, and is kept per page', (tester) async {
    await setUpRig(tester);
    for (final s in [const Size(820, 1180), const Size(1180, 820)]) {
      size(tester, s);
      await tester.pumpWidget(MaterialApp(key: UniqueKey(), theme: buildTheme(CacheThemeId.light), home: SettingsScreen(deps: r.deps)));
      await settle(tester);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.byTooltip('Show Settings'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('pane-hide')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Hide list').hitTestable(), findsNothing, reason: 'the list slid away');
      expect(find.byTooltip('Show Settings'), findsOneWidget);
      // the detail's own top bar, left of its title
      final show = tester.getCenter(find.byKey(const ValueKey('pane-show')));
      final title = tester.getTopLeft(find.descendant(of: find.byType(AppBar), matching: find.text('Cache model and web search')));
      expect(show.dx, lessThan(title.dx));
      expect(File('${dir.path}/panes.json').readAsStringSync(), '{"settings":true}');
      await tester.tap(find.byKey(const ValueKey('pane-show')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Hide list'), findsOneWidget);
      expect(File('${dir.path}/panes.json').readAsStringSync(), '{"settings":false}');
    }
    await tearDownRig(tester);
  });
}
