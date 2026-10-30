import 'package:cache/app_state.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/models/hf_hub.dart';
import 'package:cache/models/model_downloads.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/screens/settings/deps.dart';
import 'package:cache/screens/setup_card.dart';
import 'package:cache/screens/weather_turn_on.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

/// The regions on the phone, as the test sets them.
class _Regions extends RegionsState {
  _Regions(SettingsRig r)
    : super(policy: r.policy, supportDir: () async => r.dir, catalogue: RegionCatalogue(dir: () async => r.dir), maps: r.maps);

  List<LocalRegion> onPhone = [];

  @override
  List<LocalRegion> get local => onPhone;

  void set(List<LocalRegion> l) {
    onPhone = l;
    notifyListeners();
  }
}

LocalRegion _region(String state, {int done = 0}) => LocalRegion(
  id: 'us-wasatch',
  name: 'Wasatch Front',
  routing: {'state': state, 'bytes': 100 << 20, 'done_bytes': state == 'ready' ? 100 << 20 : done << 20},
  places: {'state': state, 'bytes': 20 << 20, 'done_bytes': state == 'ready' ? 20 << 20 : 0},
);

void main() {
  late SettingsRig r;
  late LayoutState layout;
  late _Regions regions;
  late ModelDownloads downloads;
  late List<String> opened;
  late SetupCache setup;

  Future<void> rig(WidgetTester tester) async {
    r = await SettingsRig.create(tester);
    layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    regions = _Regions(r);
    downloads = ModelDownloads(app: r.app);
    opened = [];
    setup = SetupCache(
      layout: layout,
      app: r.app,
      weather: r.weather,
      sources: r.sources,
      regions: regions,
      browse: r.browse,
      modelDownloads: downloads,
      chooseModel: (_) => opened.add('models'),
      getArea: (_) => opened.add('area'),
      turnOnWeather: (_) => opened.add('weather'),
      addLibrary: (_) => opened.add('library'),
    );
  }

  Future<void> home(WidgetTester tester) async {
    await r.show(tester, HomeScreen(layout: layout, setup: setup, onOpenAsk: () {}, onOpenSettings: () {}, onOpenShortcut: (_) {}));
    await tester.pumpAndSettle();
  }

  void model() => r.app.models = [ModelEntry(path: '${r.modelsDir.path}/gemma-4-E2B-it-Q4_K_M.gguf', size: 3 << 30)];

  void zim() {
    final path = '${r.sources.zimsDir!.path}/wikipedia_en_all_nopic.zim';
    r.sources.zims = [ZimFile(path: path, size: 1 << 30)];
    r.sources.titles[path] = 'Wikipedia';
  }

  Future<void> weatherOn(WidgetTester tester) => tester.runAsync(() => r.weather.setRowOn(WeatherTurnOn.rows.first, true));

  Finder row(String key) => find.byKey(ValueKey(key));
  Finder tickIn(String key) => find.descendant(of: row(key), matching: find.byKey(const ValueKey('setup-tick')));

  testWidgets('fresh install: four lines to do, each with its reason, and each opens its screen', (tester) async {
    await rig(tester);
    await home(tester);
    expect(find.byKey(const ValueKey('setup-card')), findsOneWidget);
    expect(find.text('Set up Cache'), findsOneWidget);
    expect(find.text('0 of 4 done'), findsOneWidget);
    for (final t in ['Choose a model', 'Get your area', 'Turn on weather', 'Add a library']) {
      expect(find.text(t), findsOneWidget);
    }
    expect(find.text('Needed to answer questions'), findsOneWidget);
    expect(find.text('Map, directions and places'), findsOneWidget);
    expect(find.text('Forecast and alerts'), findsOneWidget);
    expect(find.text('Wikipedia, WikiMed or your own'), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-tick')), findsNothing);
    expect(find.byKey(const ValueKey('setup-progress')), findsNothing);
    for (final k in ['setup-model', 'setup-area', 'setup-weather', 'setup-library']) {
      await tester.tap(row(k));
      await tester.pump();
    }
    expect(opened, ['models', 'area', 'weather', 'library']);
    await r.dispose(tester);
  });

  testWidgets('partly done: a chat model on the phone and a ZIM are ticked with what they are', (tester) async {
    await rig(tester);
    model();
    zim();
    await home(tester);
    expect(find.text('2 of 4 done'), findsOneWidget);
    expect(tickIn('setup-model'), findsOneWidget);
    expect(tickIn('setup-library'), findsOneWidget);
    expect(tickIn('setup-area'), findsNothing);
    expect(tickIn('setup-weather'), findsNothing);
    expect(find.text('gemma-4-E2B-it-Q4_K_M · 3.0 GB'), findsOneWidget);
    expect(find.text('Wikipedia'), findsOneWidget);
    await tester.tap(row('setup-model'));
    await tester.pump();
    expect(opened, isEmpty, reason: 'a done line has no button');
    await r.dispose(tester);
  });

  testWidgets('in progress: the model and region downloads show their progress, and a region counts once its routing is in', (tester) async {
    await rig(tester);
    downloads
      ..current = const HfFile(repo: 'unsloth/gemma-4-E2B-it-GGUF', path: 'gemma-4-E2B-it-Q4_K_M.gguf', size: 100)
      ..done = 34
      ..total = 100;
    regions.onPhone = [_region('downloading', done: 50)];
    await home(tester);
    expect(find.text('0 of 4 done'), findsOneWidget);
    expect(find.text('gemma-4-E2B-it-Q4_K_M.gguf · downloading 34%'), findsOneWidget);
    expect(find.textContaining('Wasatch Front · downloading'), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-progress')), findsNWidgets(2));
    final bar = tester.widget<LinearProgressIndicator>(
      find.descendant(of: row('setup-model'), matching: find.byKey(const ValueKey('setup-progress'))),
    );
    expect(bar.value, closeTo(0.34, 1e-9));

    regions.set([_region('ready')]);
    await tester.pumpAndSettle();
    expect(find.text('1 of 4 done'), findsOneWidget);
    expect(tickIn('setup-area'), findsOneWidget);
    expect(find.text('Wasatch Front · directions and places · 120 MB'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('all done: the card goes away; Settings > Set up Cache still shows the four ticks', (tester) async {
    await rig(tester);
    model();
    zim();
    regions.onPhone = [_region('ready')];
    await weatherOn(tester);
    await home(tester);
    expect(find.byKey(const ValueKey('setup-card')), findsNothing);
    expect(find.text('Set up Cache'), findsNothing);

    await r.show(tester, SettingsScreen(deps: _deps(r, setup)));
    await tester.pumpAndSettle();
    expect(find.text('4 of 4 done'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-setup')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('setup-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-tick')), findsNWidgets(4));
    expect(find.text('Weather and alerts on'), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-hide')), findsNothing);
    await r.dispose(tester);
  });

  testWidgets('dismissed: Hide removes the card, is remembered, and Settings > Set up Cache brings it back', (tester) async {
    await rig(tester);
    model();
    await home(tester);
    expect(find.text('1 of 4 done'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('setup-hide')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('setup-card')), findsNothing);
    expect(find.text('You can find this again in Settings > Set up Cache.'), findsOneWidget);
    expect(layout.setupHidden, isTrue);

    final again = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(again.init);
    expect(again.setupHidden, isTrue, reason: 'kept in layout.json');

    await r.show(tester, SettingsScreen(deps: _deps(r, setup)));
    await tester.pumpAndSettle();
    expect(find.text('1 of 4 done'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-setup')));
    await tester.pumpAndSettle();
    expect(layout.setupHidden, isFalse);
    expect(find.byKey(const ValueKey('setup-card')), findsOneWidget);

    await home(tester);
    expect(find.byKey(const ValueKey('setup-card')), findsOneWidget);
    await r.dispose(tester);
  });
}

SettingsDeps _deps(SettingsRig r, SetupCache setup) => SettingsDeps(
  app: r.app,
  chat: r.chat,
  sources: r.sources,
  maps: r.maps,
  video: r.video,
  browse: r.browse,
  location: r.location,
  hub: r.hub,
  setup: setup,
);
