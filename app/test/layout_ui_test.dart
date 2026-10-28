import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:cache/layout/edit_home_screen.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/layout/modules.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/theme.dart';
import 'package:cache/video/token_store.dart';
import 'package:cache/video/video_state.dart';
import 'package:cache_search/cache_search.dart' show MapPlace;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';
import 'nav_fakes.dart';
import 'support/settings_rig.dart';
import 'support/test_layer_engine.dart';
import 'video_fake.dart';

class _NoSource implements PositionSource {
  @override
  Future<LocationPermissionState> permission() async => LocationPermissionState.granted;
  @override
  Future<LocationPermissionState> requestPermission() async => LocationPermissionState.granted;
  @override
  Future<bool> serviceEnabled() async => true;
  @override
  Future<Fix> current() async => fixAt(42.5, -113.8);
  @override
  Stream<Fix> stream() => const Stream.empty();
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

const hospital = MapPlace(
  id: 'place:osm:n4',
  type: 'place',
  name: 'Cassia Regional Hospital',
  kind: 'Hospital',
  address: '1501 Hiland Ave, Burley, ID',
  lat: 42.5,
  lon: -113.5,
  matched: 'name',
);

/// The whole frame (Home, bar, Modules) on fakes. The Maps screen is never opened here: it needs a platform map.
class Rig {
  late Directory dir;
  late LayoutState layout;
  late AppState app;
  late ConversationStore store;
  late ChatController chat;
  late FakeSources sources;
  late BrowseState browse;
  late VideoState video;
  late LocationService location;
  late MapsState maps;
  late NavState nav;
  late SettingsRig settingsRig;

  Future<void> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    dir = Directory.systemTemp.createTempSync('layout-ui');
    layout = LayoutState(settingsDirOverride: dir);
    app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
    store = ConversationStore.memory();
    chat = ChatController(tools: const [])..attachStore(store);
    sources = FakeSources(Directory('${dir.path}/zims')..createSync());
    browse = BrowseState(sources: sources, policy: testPolicy(), settingsDirOverride: dir, phoneLanguage: 'en');
    video = VideoState(dirOverride: Directory('${dir.path}/videos'), nativeFactory: fakeVideoNative, tokens: MemoryTokenStore());
    location = LocationService(source: _NoSource(), settingsDirOverride: dir);
    maps = MapsState(engine: TestLayerEngine(), settingsDirOverride: dir);
    nav = NavState(
      backend: FakeBackend(),
      location: location,
      speaker: FakeSpeaker(),
      positionSource: FakeNavPosition(),
      fmt: const Fmt(UnitSystem.imperial),
    );
    settingsRig = await SettingsRig.create(tester);
    await tester.runAsync(() async {
      await layout.init();
      await browse.init();
      await video.init();
    });
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: Shell(
        app: app,
        chat: chat,
        sources: sources,
        location: location,
        maps: maps,
        video: video,
        browse: browse,
        nav: nav,
        layout: layout,
        hub: settingsRig.hub,
      ),
    ));
    await tester.pump();
  }

  Future<void> stop(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    nav.dispose();
    video.dispose();
    browse.dispose();
    sources.dispose();
    store.close();
    layout.dispose();
    await settingsRig.dispose(tester);
    await tester.runAsync(() => dir.delete(recursive: true));
  }
}

/// The labels in the bottom bar, left to right.
List<String> barLabels(WidgetTester tester) {
  final bar = find.byType(NavigationBar);
  final items = find.descendant(of: bar, matching: find.byType(NavigationDestination));
  final out = <(double, String)>[];
  for (final e in items.evaluate()) {
    final w = e.widget as NavigationDestination;
    out.add((tester.getTopLeft(find.byWidget(w)).dx, w.label));
  }
  out.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final o in out) o.$2];
}

Future<void> openModules(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Modules')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> openModuleMenu(WidgetTester tester, ModuleId m) async {
  await tester.longPress(find.byKey(ValueKey('module-${m.name}')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('the bar starts as Home, Ask, Maps, Library, Modules', (tester) async {
    final r = Rig();
    await r.start(tester);
    expect(barLabels(tester), ['Home', 'Ask', 'Maps', 'Library', 'Modules']);
    await r.stop(tester);
  });

  testWidgets('a 4th pin says the bar is full and replacing one keeps Home first and Modules last, at 5 items', (tester) async {
    final r = Rig();
    await r.start(tester);
    await openModules(tester);
    expect(find.byKey(const ValueKey('module-videos')), findsOneWidget);

    await openModuleMenu(tester, ModuleId.videos);
    await tester.tap(find.text('Pin to bar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('The bar is full (3 max)'), findsOneWidget);
    expect(r.layout.pinned, [ModuleId.ask, ModuleId.maps, ModuleId.library], reason: 'nothing changed yet');

    await tester.tap(find.text('Replace Library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(barLabels(tester), ['Home', 'Ask', 'Maps', 'Videos', 'Modules']);
    expect(barLabels(tester), hasLength(5));
    await r.stop(tester);
  });

  testWidgets('unpin frees a slot; pinning then fits without asking', (tester) async {
    final r = Rig();
    await r.start(tester);
    await openModules(tester);
    await openModuleMenu(tester, ModuleId.maps);
    expect(find.text('Unpin from bar'), findsOneWidget);
    await tester.tap(find.text('Unpin from bar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(barLabels(tester), ['Home', 'Ask', 'Library', 'Modules']);

    await openModuleMenu(tester, ModuleId.videos);
    await tester.tap(find.text('Pin to bar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('The bar is full (3 max)'), findsNothing);
    expect(barLabels(tester), ['Home', 'Ask', 'Library', 'Videos', 'Modules']);
    await r.stop(tester);
  });

  testWidgets('Add to Home on a module puts a shortcut card on Home, and the card opens that module', (tester) async {
    final r = Rig();
    await r.start(tester);
    await openModules(tester);
    await openModuleMenu(tester, ModuleId.videos);
    await tester.tap(find.text('Add to Home'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Added to Home'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Home')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final card = find.byKey(const ValueKey('shortcut-module:videos'));
    expect(card, findsOneWidget);
    await tester.tap(card);
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Videos is on screen: its own screen title, and the bar shows it is under Modules (it is not pinned)
    expect(find.text('Saved on this phone'), findsOneWidget);
    await r.stop(tester);
  });

  testWidgets('a chat shortcut opens that chat in Ask', (tester) async {
    final r = Rig();
    await r.start(tester);
    final c = r.store.create(title: 'Treating burns');
    r.store.addMessage(c.id, role: 'user', content: 'How do I treat a burn?', message: {'role': 'user', 'content': 'How do I treat a burn?'});
    r.layout.addShortcut(Shortcut.chat(id: c.id, title: 'Treating burns'));
    await tester.pump();
    expect(r.chat.activeId, isNot(c.id));
    await tester.tap(find.byKey(ValueKey('shortcut-chat:${c.id}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(r.chat.activeId, c.id);
    expect(find.text('How do I treat a burn?'), findsOneWidget);
    await r.stop(tester);
  });

  testWidgets('a place shortcut hands its place back when tapped', (tester) async {
    final dir = Directory.systemTemp.createTempSync('layout-home');
    final layout = LayoutState(settingsDirOverride: dir);
    await tester.runAsync(layout.init);
    const place = hospital;
    layout.addShortcut(Shortcut.place(place));
    Shortcut? opened;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: HomeScreen(layout: layout, onOpenAsk: () {}, onOpenSettings: () {}, onOpenShortcut: (s) => opened = s),
    ));
    await tester.tap(find.text('Cassia Regional Hospital'));
    expect(opened?.place?.id, place.id);
    expect(opened?.place?.lat, place.lat);
    await tester.pumpWidget(const SizedBox.shrink());
    layout.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  });

  testWidgets('Edit Home: switches and order change Home and persist', (tester) async {
    final r = Rig();
    await r.start(tester);
    await tester.tap(find.byKey(const ValueKey('edit-home')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(EditHomeScreen), findsOneWidget);
    expect(find.text('Needs a connection to stay current'), findsNWidgets(2), reason: 'on Weather and Alerts');
    expect(find.text('Reset to default'), findsOneWidget);

    // Weather off
    await tester.tap(find.widgetWithText(SwitchListTile, 'Weather'));
    await tester.pump();
    expect(r.layout.isOn(HomeBlock.weather), isFalse);

    // Drag Shortcuts (last) above the Ask box
    final handle = find.descendant(of: find.byKey(const ValueKey('block-shortcuts')), matching: find.byIcon(Icons.drag_handle));
    await tester.drag(handle, const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(r.layout.blockOrder.first, HomeBlock.shortcuts);

    // restart: a new LayoutState on the same folder reads the same thing
    final again = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(again.init);
    expect(again.blockOrder.first, HomeBlock.shortcuts);
    expect(again.isOn(HomeBlock.weather), isFalse);
    again.dispose();

    // Reset to default
    await tester.tap(find.text('Reset to default'));
    await tester.pump();
    expect(r.layout.blockOrder, LayoutState.defaultBlocks);
    expect(r.layout.isOn(HomeBlock.weather), isTrue);

    // back on Home: Weather card shows again
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Weather'), findsOneWidget);
    await r.stop(tester);
  });

  testWidgets('Home hides a block that is switched off and has a gear that opens Settings', (tester) async {
    final r = Rig();
    await r.start(tester);
    expect(find.text('Weather'), findsOneWidget);
    expect(find.text('Alerts'), findsOneWidget);
    r.layout.setBlockOn(HomeBlock.alerts, false);
    await tester.pump();
    expect(find.text('Alerts'), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsNothing, reason: 'the old menu is gone');
    await tester.tap(find.byKey(const ValueKey('home-settings')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Assistant'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Sharing and sync'), findsOneWidget);
    await r.stop(tester);
  });
}
