import 'package:cache/app_state.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/models/hf_hub.dart';
import 'package:cache/models/model_downloads.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/screens/home_screen.dart';
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
    await r.show(tester, HomeScreen(layout: layout, setup: setup, weather: r.weather, turnOn: _turnOn(r), onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {}));
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
    expect(find.text('The AI that answers your questions'), findsOneWidget);
    expect(find.text('Maps, directions and places for your area'), findsOneWidget);
    expect(find.text('Forecasts and alerts for your places'), findsOneWidget);
    expect(find.text('Wikipedia, medical and survival guides'), findsOneWidget);
    expect(find.byKey(const ValueKey('weather-turn-on')), findsNothing, reason: '"Turn on weather" appears once, in the setup card');
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
    expect(find.textContaining('Wasatch Front · Not offline yet'), findsOneWidget, reason: 'parts work as they land, but it is not offline yet');
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

  testWidgets('a region download that stopped says what to do in a line that fits, and the line carries it on', (tester) async {
    await rig(tester);
    regions.onPhone = [
      LocalRegion(
        id: 'us-id',
        name: 'Idaho',
        routing: {'state': 'failed', 'bytes': 150 << 20, 'done_bytes': 40 << 20, 'error': 'stopped'},
      ),
    ];
    await home(tester);
    expect(find.text('Idaho · Stopped. Tap to carry on'), findsOneWidget, reason: 'no "Tap Update" for a button that is not here');
    expect(find.textContaining('Tap Update'), findsNothing);
    expect(setup.stoppedRegion?.id, 'us-id', reason: 'the shell carries this one on when the line is tapped');
    await tester.tap(row('setup-area'));
    await tester.pump();
    expect(opened, ['area']);
    regions.set([_region('ready')]);
    expect(setup.stoppedRegion, isNull, reason: 'a region that is ready leaves nothing to carry on');
    await r.dispose(tester);
  });

  testWidgets('all done: the card goes away by itself', (tester) async {
    await rig(tester);
    model();
    zim();
    regions.onPhone = [_region('ready')];
    await weatherOn(tester);
    await home(tester);
    expect(find.byKey(const ValueKey('setup-card')), findsNothing);
    expect(find.text('Set up Cache'), findsNothing);
    await r.dispose(tester);
  });

  testWidgets('an ordinary Home block: no hide button and no Settings row; switched off in Edit Home, the weather card offers "Turn on weather"', (tester) async {
    await rig(tester);
    model();
    await home(tester);
    expect(find.text('1 of 4 done'), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-hide')), findsNothing);
    layout.setBlockOn(HomeBlock.setup, false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('setup-card')), findsNothing);
    expect(find.byKey(const ValueKey('weather-turn-on')), findsOneWidget, reason: 'now the one place it appears');
    final again = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(again.init);
    expect(again.isOn(HomeBlock.setup), isFalse, reason: 'kept in layout.json');
    again.dispose();
    await r.dispose(tester);
  });
}

WeatherTurnOn _turnOn(SettingsRig r) => WeatherTurnOn(weather: r.weather, location: r.location);
