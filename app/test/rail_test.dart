import 'dart:io';

import 'package:cache/layout/adaptive.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
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

  Future<void> shell(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      key: UniqueKey(),
      theme: buildTheme(CacheThemeId.light),
      home: Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub, railPrefs: RailPrefs(dirOverride: dir)),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> setUpRig(WidgetTester tester) async {
    r = await SettingsRig.create(tester);
    dir = Directory.systemTemp.createTempSync('rail');
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

  double railWidth(WidgetTester tester) => tester.getSize(find.byKey(const ValueKey('nav-rail'))).width;

  testWidgets('portrait: Hide menu slides the rail away, Show menu brings it back, and the choice is kept on this device', (tester) async {
    await setUpRig(tester);
    await shell(tester, const Size(820, 1180));
    expect(find.byKey(const ValueKey('nav-rail')), findsOneWidget);
    expect(find.byTooltip('Hide menu'), findsOneWidget);
    expect(find.byTooltip('Show menu'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('rail-hide')));
    await tester.pump(const Duration(milliseconds: 100));
    final mid = tester.getTopRight(find.byKey(const ValueKey('nav-rail'))).dx;
    await tester.pumpAndSettle();
    expect(tester.getTopRight(find.byKey(const ValueKey('nav-rail'))).dx, lessThanOrEqualTo(0.5), reason: 'slid out of view');
    expect(mid, greaterThan(0.5), reason: 'it slides (animated), it does not jump');
    expect(find.byTooltip('Show menu'), findsOneWidget, reason: 'the way back, also for a screen reader');
    expect(File('${dir.path}/rail.json').readAsStringSync(), '{"hidden":true}');

    // A restart: still hidden.
    await shell(tester, const Size(820, 1180));
    expect(find.byTooltip('Show menu'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rail-show')));
    await tester.pumpAndSettle();
    expect(railWidth(tester), greaterThanOrEqualTo(kRailWidth));
    expect(find.byTooltip('Show menu'), findsNothing);
    expect(File('${dir.path}/rail.json').readAsStringSync(), '{"hidden":false}');
    await tearDownRig(tester);
  });

  testWidgets('landscape: the rail stays and has no Hide menu, even when it was hidden upright', (tester) async {
    await setUpRig(tester);
    await RailPrefs(dirOverride: dir).setHidden(true);
    await shell(tester, const Size(1180, 820));
    expect(find.byKey(const ValueKey('nav-rail')), findsOneWidget);
    expect(railWidth(tester), greaterThanOrEqualTo(kRailWidth));
    expect(find.byTooltip('Hide menu'), findsNothing);
    expect(find.byTooltip('Show menu'), findsNothing);
    await tearDownRig(tester);
  });
}
