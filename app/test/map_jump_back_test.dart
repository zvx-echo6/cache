// A jump to the Maps tab from another screen ("Show on map" of a region, an area or a notebook place, an Ask map link) is
// remembered: Back on Maps returns to the screen the person was on, with the pages that were open over it opened again in the
// same order. A second Back is as before. A notification's tap, a jump from Maps itself, another tab, guidance and a new page
// over the map leave nothing remembered.
import 'dart:async';
import 'dart:io';

import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart' show TurnPhase;
import 'package:cache/layout/adaptive.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/maps/geo.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/open_maps.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart' show MapPlace;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/settings_rig.dart';

const _bounds = GeoBounds(south: 42, west: -114, north: 43, east: -113);

void main() {
  late SettingsRig r;
  late LayoutState layout;
  late NavState nav;
  var closed = 0; // how many times Back closed the app

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(seconds: 1));
  }

  String selectedTab(WidgetTester tester) {
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    return (bar.destinations[bar.selectedIndex] as NavigationDestination).label;
  }

  Future<void> start(WidgetTester tester, {bool withAnswer = false}) async {
    tester.view.physicalSize = const Size(390, 844) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    closed = 0;
    // Back with nothing left to go back to closes the app (SystemNavigator.pop).
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') closed++;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    r = await SettingsRig.create(tester);
    final dir = Directory('${r.dir.path}/layout')..createSync();
    PanePrefs.testDir = dir;
    addTearDown(() => PanePrefs.testDir = null);
    layout = LayoutState(settingsDirOverride: dir);
    await tester.runAsync(layout.init);
    nav = NavState(backend: FakeBackend(), location: r.location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
    if (withAnswer) {
      await tester.runAsync(() async {
        File('${r.modelsDir.path}/gemma-4-E2B-it-Q4_K_M.gguf').writeAsBytesSync(List.filled(16, 0));
        await r.app.refreshModels();
      });
      r.chat.messages.add(ChatMessage.assistant()
        ..phase = TurnPhase.done
        ..text = 'It is in Twin Falls.'
        ..sources = const [NumberedResult(1, SourceResult(title: 'Twin Falls', snippet: '', address: 'loc:42.5,-113.8'))]);
    }
    await tester.pumpWidget(MaterialApp(
      key: UniqueKey(),
      theme: buildTheme(CacheThemeId.light),
      navigatorObservers: [pagePushWatcher],
      home: Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub, railPrefs: RailPrefs(dirOverride: dir)),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    layout.dispose();
    await r.dispose(tester);
  }

  /// A page over the tabs (as openDetail opens one): shows [name], with a button that runs [jump].
  Future<void> openPage(WidgetTester tester, String name, VoidCallback jump) async {
    unawaited(Navigator.of(tester.element(find.byType(NavigationBar))).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(body: Column(children: [Text(name), TextButton(key: ValueKey('jump-$name'), onPressed: jump, child: const Text('go'))])),
    )));
    await settle(tester);
    expect(find.text(name), findsOneWidget);
  }

  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
    await settle(tester);
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await settle(tester);
  }

  testWidgets('region page Show on map: Back returns to Home with the region page open again', (tester) async {
    await start(tester);
    await openPage(tester, 'region page', () => r.maps.showAreaOnMap(_bounds));
    await tester.tap(find.byKey(const ValueKey('jump-region page')));
    await settle(tester);
    expect(find.text('region page'), findsNothing);
    expect(selectedTab(tester), 'Maps');

    await back(tester);
    expect(selectedTab(tester), 'Home');
    expect(find.text('region page'), findsOneWidget, reason: 'the page is open again');
    expect(closed, 0);

    // A second Back is as before: the page closes (Home stays), and the Back after it leaves the app.
    await back(tester);
    expect(find.text('region page'), findsNothing);
    expect(selectedTab(tester), 'Home');
    expect(closed, 0);
    await back(tester);
    expect(closed, 1);
    await finish(tester);
  });

  testWidgets('area page Show on map: Back returns to the module with the region page and the area page, in order', (tester) async {
    await start(tester);
    await tapTab(tester, 'Modules');
    await openPage(tester, 'region page', () {});
    await openPage(tester, 'area page', () => r.maps.showAreaOnMap(_bounds));
    await tester.tap(find.byKey(const ValueKey('jump-area page')));
    await settle(tester);
    expect(find.text('area page'), findsNothing);
    expect(find.text('region page'), findsNothing);
    expect(selectedTab(tester), 'Maps');

    await back(tester);
    expect(selectedTab(tester), 'Modules');
    expect(find.text('area page'), findsOneWidget, reason: 'the area page is on top');
    // Back closes the area page and shows the region page under it, as it was.
    await back(tester);
    expect(find.text('area page'), findsNothing);
    expect(find.text('region page'), findsOneWidget);
    expect(closed, 0);
    await back(tester);
    expect(find.text('region page'), findsNothing);
    expect(selectedTab(tester), 'Modules');
    await back(tester);
    expect(closed, 1);
    await finish(tester);
  });

  testWidgets('notebook place Show on map: Back returns to the notebook page', (tester) async {
    await start(tester);
    await openPage(tester, 'notebook place', () => nav.showPlace(const MapPlace(id: 'place:42.5,-113.5', type: 'place', name: 'Fernwood Trailhead', kind: '', lat: 42.5, lon: -113.5)));
    await tester.tap(find.byKey(const ValueKey('jump-notebook place')));
    await settle(tester);
    expect(find.text('notebook place'), findsNothing);
    expect(selectedTab(tester), 'Maps');

    await back(tester);
    expect(selectedTab(tester), 'Home');
    expect(find.text('notebook place'), findsOneWidget);
    await back(tester);
    expect(find.text('notebook place'), findsNothing);
    expect(closed, 0);
    await back(tester);
    expect(closed, 1);
    await finish(tester);
  });

  testWidgets('an Ask map link: Back returns to Ask', (tester) async {
    await start(tester, withAnswer: true);
    await tapTab(tester, 'Ask');
    expect(find.byType(AskScreen), findsOneWidget);
    await tester.tap(find.text('1 source'));
    await settle(tester);
    await tester.tap(find.textContaining('[1] Twin Falls'));
    await settle(tester);
    expect(selectedTab(tester), 'Maps');
    expect(nav.selected?.name, 'Twin Falls');

    await back(tester);
    expect(selectedTab(tester), 'Ask');
    expect(find.byType(AskScreen), findsOneWidget);
    // A second Back is as before: nothing to go back to, the app closes.
    await back(tester);
    expect(closed, 1);
    await finish(tester);
  });

  testWidgets('a notification tap: nothing is remembered, Back is as today', (tester) async {
    await start(tester);
    await openPage(tester, 'some page', () {});
    openMapsInbox.offer('maps');
    await settle(tester);
    expect(find.text('some page'), findsNothing);
    expect(selectedTab(tester), 'Maps');

    await back(tester);
    expect(closed, 1, reason: 'Back leaves the app, as before');
    expect(find.text('some page'), findsNothing);
    await finish(tester);
  });

  testWidgets('a jump from the Maps tab itself remembers nothing', (tester) async {
    await start(tester);
    await tapTab(tester, 'Maps');
    expect(selectedTab(tester), 'Maps');
    nav.showPlace(const MapPlace(id: 'place:42.5,-113.5', type: 'place', name: 'Fernwood Trailhead', kind: '', lat: 42.5, lon: -113.5));
    await settle(tester);
    expect(selectedTab(tester), 'Maps');

    await back(tester);
    expect(closed, 1, reason: 'Back leaves the app, as before');
    await finish(tester);
  });

  testWidgets('tapping another tab clears the record', (tester) async {
    await start(tester);
    await openPage(tester, 'region page', () => r.maps.showAreaOnMap(_bounds));
    await tester.tap(find.byKey(const ValueKey('jump-region page')));
    await settle(tester);
    expect(selectedTab(tester), 'Maps');

    await tapTab(tester, 'Modules');
    await tapTab(tester, 'Maps');
    expect(selectedTab(tester), 'Maps');
    await back(tester);
    expect(closed, 1, reason: 'Back leaves the app, as before');
    expect(find.text('region page'), findsNothing);
    await finish(tester);
  });
}
