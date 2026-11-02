import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/sources/libraries_state.dart';
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
      openGuide: (_, title) => opened.add(title),
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

  /// "(N of 4 done)" in the card's line under its title.
  Finder count(int n) => find.textContaining('($n of 4 done)', findRichText: true);
  Finder tickIn(String key) => find.descendant(of: row(key), matching: find.byKey(const ValueKey('setup-tick')));

  testWidgets('fresh install: four lines to do, each with its reason, and each opens its screen', (tester) async {
    await rig(tester);
    await home(tester);
    expect(find.byKey(const ValueKey('setup-card')), findsOneWidget);
    expect(find.text('Set up Cache'), findsOneWidget);
    expect(count(0), findsOneWidget);
    for (final t in ['Choose a model', 'Get your area', 'Turn on weather', 'Add a library']) {
      expect(find.text(t), findsOneWidget);
    }
    expect(find.text('Optional. Lets you ask in plain words.'), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-not-now')), findsOneWidget, reason: 'models are never required');
    expect(find.text('Maps, directions and places for your area'), findsOneWidget);
    expect(find.text('Forecasts and alerts for your places'), findsOneWidget);
    expect(find.text('Wikipedia, medical and survival guides'), findsOneWidget);
    expect(find.byKey(const ValueKey('weather-turn-on')), findsNothing, reason: '"Turn on weather" appears once, in the setup card');
    expect(find.byKey(const ValueKey('setup-tick')), findsNothing);
    expect(find.byKey(const ValueKey('setup-progress')), findsNothing);
    // Each row by its title (the model row also has "Not now" at its right, which does something else).
    for (final (k, t) in [('setup-model', 'Choose a model'), ('setup-area', 'Get your area'), ('setup-weather', 'Turn on weather'), ('setup-library', 'Add a library')]) {
      await tester.tap(find.descendant(of: row(k), matching: find.text(t)));
      await tester.pump();
    }
    expect(opened, ['models', 'area', 'weather', 'library']);
    expect(r.app.modelDeclined, isFalse, reason: 'tapping the row opens Models; it is not "Not now"');
    await r.dispose(tester);
  });

  testWidgets('"Not now" on the model row: search only, ticked and counted, with Undo; kept, and a model replaces it', (tester) async {
    await rig(tester);
    await home(tester);
    expect(count(0), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('setup-not-now')));
    await tester.pump();
    expect(opened, isEmpty, reason: '"Not now" does not open Models');
    expect(find.text('Ask is off. You can add a model any time.'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tickIn('setup-model'), findsOneWidget);
    expect(find.text('Search only on this device. Tap to add one.'), findsOneWidget);
    expect(count(1), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-not-now')), findsNothing);
    expect(r.app.modelDeclined, isTrue);
    // The settings are written in the background (a new file renamed over the old): wait for the write, bounded, rather than a
    // fixed number of turns (5 x 20 ms was too short on a busy runner, run 41411094494).
    final settings = File('${r.dir.path}/settings.json');
    for (var i = 0; i < 150 && !(settings.existsSync() && settings.readAsStringSync().contains('"modelDeclined":true')); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(jsonDecode(settings.readAsStringSync())['modelDeclined'], isTrue, reason: 'kept on this device');
    // A done row is never dead: it opens Models, where the person can change their mind.
    await tester.tap(row('setup-model'));
    await tester.pump();
    expect(opened, ['models']);
    // Undo puts the row back as it was.
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(r.app.modelDeclined, isFalse);
    expect(tickIn('setup-model'), findsNothing);
    expect(find.text('Optional. Lets you ask in plain words.'), findsOneWidget);
    // Declined again, then a model arrives: the row shows the model.
    await tester.tap(find.byKey(const ValueKey('setup-not-now')));
    await tester.pumpAndSettle();
    model();
    await tester.runAsync(() => r.app.setTheme(r.app.theme));
    await tester.pumpAndSettle();
    expect(find.text('gemma-4-E2B-it-Q4_K_M · 3.0 GB'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('partly done: a chat model on the phone and a ZIM are ticked with what they are', (tester) async {
    await rig(tester);
    model();
    zim();
    await home(tester);
    expect(count(2), findsOneWidget);
    expect(tickIn('setup-model'), findsOneWidget);
    expect(tickIn('setup-library'), findsOneWidget);
    expect(tickIn('setup-area'), findsNothing);
    expect(tickIn('setup-weather'), findsNothing);
    expect(find.text('gemma-4-E2B-it-Q4_K_M · 3.0 GB'), findsOneWidget);
    expect(find.text('Wikipedia'), findsOneWidget);
    await tester.tap(row('setup-model'));
    await tester.pump();
    expect(opened, ['models'], reason: 'a done line still opens its screen (it is not dead)');
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
    expect(count(0), findsOneWidget);
    expect(find.text('gemma-4-E2B-it-Q4_K_M.gguf · downloading 34%'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Wasatch Front · Directions \d+%')), findsOneWidget, reason: 'the same words as the region\'s row in Regions');
    expect(find.byKey(const ValueKey('setup-progress')), findsNWidgets(2));
    final bar = tester.widget<LinearProgressIndicator>(
      find.descendant(of: row('setup-model'), matching: find.byKey(const ValueKey('setup-progress'))),
    );
    expect(bar.value, closeTo(0.34, 1e-9));

    regions.set([_region('ready')]);
    await tester.pumpAndSettle();
    expect(count(1), findsOneWidget);
    expect(tickIn('setup-area'), findsOneWidget);
    expect(find.text('Wasatch Front · Ready'), findsOneWidget);
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
    expect(find.text("Idaho · Directions couldn't finish. Tap to carry on"), findsOneWidget, reason: 'no "Tap Update" for a button that is not here');
    expect(find.textContaining('Tap Update'), findsNothing);
    expect(setup.stoppedRegion?.id, 'us-id', reason: 'the shell carries this one on when the line is tapped');
    await tester.tap(row('setup-area'));
    await tester.pump();
    expect(opened, ['area']);
    // The tap starts a download: the line says so at once, with a spinner instead of its circle.
    expect(find.text('Starting…'), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-starting')), findsOneWidget);
    regions.set([_region('ready')]);
    expect(setup.stoppedRegion, isNull, reason: 'a region that is ready leaves nothing to carry on');
    await r.dispose(tester);
  });

  testWidgets('each line opens its section of the guide, the same section the assistant points to', (tester) async {
    await rig(tester);
    await home(tester);
    // The guide is in the line's press-and-hold menu (the ? buttons are gone).
    await tester.longPress(row('setup-area'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('setup-area-guide')));
    await tester.pumpAndSettle();
    expect(opened, ['Cache guide: 1. Getting started: Download a region']);
    expect(SetupCache.guideTitles, [
      'Cache guide: 1. Getting started: Choose a model',
      'Cache guide: 1. Getting started: Download a region',
      'Cache guide: 1. Getting started: Turn on weather and alerts',
      'Cache guide: 1. Getting started: Add to your Library',
    ]);
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

  testWidgets('Hide switches the block off, with Undo; Edit Home brings it back; then the weather card offers "Turn on weather"', (tester) async {
    await rig(tester);
    model();
    await home(tester);
    expect(count(1), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('setup-hide')));
    await tester.pump();
    expect(find.text('Set up Cache hidden. Bring it back in Edit Home.'), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-card')), findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('setup-card')), findsOneWidget, reason: 'Undo puts it back');
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

  testWidgets('the Cache guide that ships with the app does not tick "Add a library"; a library the person added does', (tester) async {
    await rig(tester);
    final libs = LibrariesState(sources: r.sources);
    libs.libraries = [LibraryItem(dir: Directory('${r.dir.path}/libraries/guide'), settings: const {'library_id': kGuideLibraryId, 'title': 'Cache guide'})];
    final browse = BrowseState(sources: r.sources, policy: r.policy, libraries: libs, settingsDirOverride: r.dir, phoneLanguage: 'en');
    SetupCache withBrowse() => SetupCache(app: r.app, weather: r.weather, sources: r.sources, browse: browse, chooseModel: (_) {}, getArea: (_) {}, turnOnWeather: (_) {}, addLibrary: (_) {});
    expect(withBrowse().libraryLine.phase, SetupPhase.todo, reason: 'only the built-in guide is there');
    libs.libraries = [...libs.libraries, LibraryItem(dir: Directory('${r.dir.path}/libraries/family-plan'), settings: const {'library_id': 'family-plan', 'title': 'Family plan'})];
    expect(withBrowse().libraryLine.phase, SetupPhase.done);
    expect(withBrowse().libraryLine.detail, '1 library');
    browse.dispose();
    await r.dispose(tester);
  });
}

WeatherTurnOn _turnOn(SettingsRig r) => WeatherTurnOn(weather: r.weather, location: r.location);
