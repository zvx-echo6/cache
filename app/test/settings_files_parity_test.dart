// settings_files.dart (no Flutter) reads and writes the 17 synced settings straight from the support folder's files. For every key:
// the value it reads from the files the real state class saved is the one the setting's read() gives, and a value it writes is
// what a fresh state class reads back from the same files, with every other field of the file as it was.

import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/layout/modules.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/sharing/settings_files.dart';
import 'package:cache/sharing/synced_settings.dart';
import 'package:cache/sharing/settings_sync.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/weather_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';
import 'support/test_layer_engine.dart';
import 'support/weather_fakes.dart';

/// Two different non-default values for a key, set through the real state class (the setting's own write).
class Case {
  const Case(this.key, this.a, this.b);

  final String key;
  final Object? a;
  final Object? b;
}

Map<String, Object?> sc(String kind, String title, String subtitle, Map<String, Object?> data) => {'kind': kind, 'title': title, 'subtitle': subtitle, 'data': data};

final List<Case> cases = [
  const Case('appearance.theme', 'parchment', 'tactical'),
  const Case('appearance.module_icons', 'large', 'small'),
  const Case('appearance.dark_pdf_pages', true, false),
  const Case('home.bar', ['weather', 'maps'], ['library', 'notebooks', 'ask']),
  const Case('home.blocks', {'order': ['shortcuts', 'ask'], 'off': ['weather']}, {'order': ['weather', 'setup'], 'off': ['ask', 'setup']}),
  Case(
    'home.shortcuts',
    [sc('module', 'Maps', '', {'module': 'maps'}), sc('notebook', 'Log: Water', 'Quick add', {'id': 'nb1', 'log': true})],
    [
      sc('chat', 'Chat x', 'Chat', {'id': 7}),
      sc('page', 'A page', 'Library page', {'address': 'zim:abc/A/Page'}),
      sc('place', 'Cafe', 'cafe', {'id': 'p1', 'type': 'place', 'kind': 'cafe', 'address': '1 Main', 'lat': 42.5, 'lon': -113.8, 'matched': '', 'formats': <String, Object?>{}}),
    ],
  ),
  const Case('weather.sources_on', ['river-a', 'river-b'], ['river-c']),
  const Case('weather.watch_here', false, true),
  const Case('weather.watch_regions', ['Idaho'], ['Oregon', 'Utah']),
  const Case('weather.watch_places', ['k1'], ['k2', 'k3']),
  Case(
    'weather.own_sources',
    [
      {'entry': entry('own-a', 'water', 'River A', path: 'defs/own-a.json'), 'definition': miniDefinition('own-a')},
    ],
    [
      {'entry': entry('own-c', 'water', 'River C', path: 'defs/own-c.json', keyAlias: 'ck'), 'definition': miniDefinition('own-c', keyAlias: 'ck')},
      {'entry': entry('own-b', 'water', 'River B', path: 'defs/own-b.json'), 'definition': miniDefinition('own-b')},
    ],
  ),
  const Case('weather.source_links', ['https://a.example/list.json'], ['https://b.example/one.json', 'https://c.example/two.json']),
  const Case('alerts.pop_up', 'all', 'none'),
  const Case('alerts.quiet_hours', {'on': false, 'from': 1380, 'to': 420}, {'on': true, 'from': 60, 'to': 120}),
  const Case('maps.layers_on', ['hillshade'], ['contours', 'landcover']),
  const Case('ask.model', 'a.gguf', 'b.gguf'),
  const Case('ask.web_search', true, false),
];

/// The value as the log writes it: plain JSON, so a list of strings and a list typed as Object compare the same.
String canon(Object? v) => jsonEncode(v);

class Classes {
  Classes(this.app, this.layout, this.settings, this.maps, this.weather, {this.ownsWeather = false});

  final bool ownsWeather;

  final AppState app;
  final LayoutState layout;
  final AppSettings settings;
  final MapsState maps;
  final WeatherState weather;

  List<SyncedSetting> get list => appSyncedSettings(app: app, layout: layout, settings: settings, maps: maps, weather: weather);

  SyncedSetting at(String key) => list.firstWhere((s) => s.key == key);

  void dispose() {
    app.dispose();
    layout.dispose();
    settings.dispose();
    maps.dispose();
    if (ownsWeather) weather.dispose();
  }
}

/// The state classes opened from the files in the rig's folder as they are now (a fresh start of the app).
Future<Classes> fresh(SettingsRig r, {bool weatherToo = false}) async {
  final settings = AppSettings(settingsDirOverride: r.dir);
  await settings.init();
  final app = AppState(settingsDirOverride: r.dir, modelsDirOverride: r.modelsDir);
  await app.init();
  final layout = LayoutState(settingsDirOverride: r.dir);
  await layout.init();
  final maps = MapsState(engine: TestLayerEngine(policy: r.policy), settingsDirOverride: r.dir);
  await maps.init();
  var weather = r.weather;
  if (weatherToo) {
    weather = WeatherState(
      settings: settings,
      policy: r.policy,
      core: FakeLiveCore(r.liveDir),
      secrets: r.secrets,
      catalogueDir: () async => r.catalogueDir,
      liveDir: () async => r.liveDir,
      builtIns: () async => builtInDefinitions(),
      position: () => r.here,
      regions: () => r.regionList,
      fetch: r.web.fetch,
      ownFetch: r.web.tryFetch,
      clock: () => r.clock,
    );
    await weather.start();
    while (weather.refreshingCatalogues) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
  return Classes(app, layout, settings, maps, weather, ownsWeather: weatherToo);
}

Map<String, dynamic>? fileJson(Directory dir, String name) {
  final f = File('${dir.path}/$name');
  if (!f.existsSync()) return null;
  return (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
}

void main() {
  test('the names settings_files.dart keeps are the app\'s own (themes, modules, Home blocks, alerts, shortcut kinds, the bar size)', () {
    expect(kThemeNames, [for (final t in CacheThemeId.values) t.name]);
    expect(kModuleNames, [for (final m in ModuleId.values) m.name]);
    expect(kMaxPinnedModules, kMaxPinned);
    expect(kHomeBlockNames, [for (final b in LayoutState.defaultBlocks) b.name]);
    expect(kHomeBlockNames, [for (final b in HomeBlock.values) b.name]);
    expect(kPopUpNames, [for (final p in PopUpFor.values) p.name]);
    expect(kShortcutKindNames, [for (final k in ShortcutKind.values) k.name]);
    expect(kDefaultPinnedNames, [for (final m in LayoutState.defaultPinned) m.name]);
  });

  testWidgets('every key in appSyncedSettings has an entry in settings_files.dart, and a case here', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    final keys = [
      for (final s in appSyncedSettings(app: r.app, layout: layout, settings: r.settings, maps: r.maps, weather: r.weather)) s.key,
    ];
    expect(keys.length, 17);
    for (final k in keys) {
      expect(kSettingsFileMap.containsKey(k), isTrue, reason: '$k has no entry in settings_files.dart');
      expect(cases.any((c) => c.key == k), isTrue, reason: '$k has no case in this test');
    }
    expect(kSettingsFileMap.keys.toSet(), keys.toSet(), reason: 'settings_files.dart has a key appSyncedSettings does not');
    layout.dispose();
    await r.dispose(tester);
  });

  for (final c in cases) {
    testWidgets('${c.key}: files and the state class read and write the same', (tester) async {
      final r = await SettingsRig.create(tester);
      final layout = LayoutState(settingsDirOverride: r.dir);
      Classes? second;
      await tester.runAsync(() async {
        await layout.init();
        File('${r.modelsDir.path}/a.gguf').writeAsBytesSync(List.filled(16, 0));
        File('${r.modelsDir.path}/b.gguf').writeAsBytesSync(List.filled(16, 0));
        await r.app.refreshModels();
        final live = Classes(r.app, layout, r.settings, r.maps, r.weather);
        // The other fields maps.json keeps beside the layers on.
        r.maps.setOpacity('landcover', 0.4);
        r.maps.rememberCamera(42.5, -113.8, 9);
        await r.maps.flush();

        await live.at(c.key).write(c.b);
        await r.maps.flush();
        final b = live.at(c.key).read();
        await live.at(c.key).write(c.a);
        await r.maps.flush();
        final a = live.at(c.key).read();
        expect(canon(a), isNot(canon(b)), reason: 'the two values must differ');

        final files = SettingsFiles(IoSettingsFileAccess(r.dir));
        expect(canon(await files.read(c.key)), canon(a), reason: 'read(${c.key}) from the files the state class saved');

        final spec = kSettingsFileMap[c.key]!;
        final before = fileJson(r.dir, spec.file);
        expect(before, isNotNull, reason: '${spec.file} was saved by the state class');
        await files.write(c.key, b);
        final after = fileJson(r.dir, spec.file)!;
        for (final f in {...before!.keys, ...after.keys}) {
          if (spec.fields.contains(f)) continue;
          expect(canon(after[f]), canon(before[f]), reason: 'field $f of ${spec.file} must stay as it was');
        }
        expect(canon(await files.read(c.key)), canon(b), reason: 'read(${c.key}) gives back what write(${c.key}) wrote');

        second = await fresh(r, weatherToo: c.key == 'weather.own_sources');
        expect(canon(second!.at(c.key).read()), canon(b), reason: 'a fresh state class reads the value settings_files.dart wrote');
      });
      second?.dispose();
      layout.dispose();
      await r.dispose(tester);
    });
  }

  testWidgets('a folder with no files reads as a new phone does (every key but the layers, which the engine fills in at start)', (tester) async {
    final r = await SettingsRig.create(tester);
    await tester.runAsync(() async {
      final empty = Directory.systemTemp.createTempSync('settings-files-empty');
      addTearDown(() => empty.deleteSync(recursive: true));
      final files = SettingsFiles(IoSettingsFileAccess(empty));
      final emptyRig = Directory.systemTemp.createTempSync('settings-files-fresh');
      addTearDown(() => emptyRig.deleteSync(recursive: true));
      final settings = AppSettings(settingsDirOverride: emptyRig);
      await settings.init();
      final app = AppState(settingsDirOverride: emptyRig, modelsDirOverride: Directory('${emptyRig.path}/models'));
      await app.init();
      final layout = LayoutState(settingsDirOverride: emptyRig);
      await layout.init();
      final live = Classes(app, layout, settings, r.maps, r.weather);
      for (final s in live.list) {
        if (s.key == 'maps.layers_on' || s.key == 'weather.own_sources') continue;
        expect(canon(await files.read(s.key)), canon(s.read()), reason: s.key);
      }
      expect(await files.read('weather.own_sources'), isEmpty);
      app.dispose();
      layout.dispose();
      settings.dispose();
    });
    await r.dispose(tester);
  });

  testWidgets('Home saved as hidden before it was a block reads as Set up Cache off, and a write of the blocks drops that note', (tester) async {
    final r = await SettingsRig.create(tester);
    await tester.runAsync(() async {
      File('${r.dir.path}/layout.json').writeAsStringSync(jsonEncode({
        'pinned': ['ask'],
        'blocks': ['ask', 'weather'],
        'off': <String>[],
        'setupHidden': true,
        'shortcuts': <Object?>[],
      }));
      final files = SettingsFiles(IoSettingsFileAccess(r.dir));
      final layout = LayoutState(settingsDirOverride: r.dir);
      await layout.init();
      expect(canon(await files.read('home.blocks')), canon(layout.blocksJson));
      expect(((await files.read('home.blocks')) as Map)['off'], ['setup']);
      await files.write('home.blocks', {'order': ['ask'], 'off': <String>[]});
      final back = LayoutState(settingsDirOverride: r.dir);
      await back.init();
      expect(canon(back.blocksJson), canon(await files.read('home.blocks')));
      expect(back.blocksJson['off'], isEmpty, reason: 'the phone drops the old note when it saves');
      expect(fileJson(r.dir, 'layout.json')!['pinned'], ['ask']);
      layout.dispose();
      back.dispose();
    });
    await r.dispose(tester);
  });

  testWidgets('watched places saved before weatherWatch (watchedPlaces only) read the same, and a write keeps both fields', (tester) async {
    final r = await SettingsRig.create(tester);
    await tester.runAsync(() async {
      File('${r.dir.path}/preferences.json').writeAsStringSync(jsonEncode({
        'watchedPlaces': ['place:k1', 'region:Idaho'],
        'someNewerKey': {'x': 1},
      }));
      final files = SettingsFiles(IoSettingsFileAccess(r.dir));
      final s1 = AppSettings(settingsDirOverride: r.dir);
      await s1.init();
      expect(canon(await files.read('weather.watch_here')), canon(s1.watchHere));
      expect(canon(await files.read('weather.watch_regions')), canon(s1.watchedRegions.toList()..sort()));
      expect(canon(await files.read('weather.watch_places')), canon(s1.watchedSavedPlaces.toList()..sort()));
      await files.write('weather.watch_regions', ['Oregon']);
      final j = fileJson(r.dir, 'preferences.json')!;
      expect(j['someNewerKey'], {'x': 1});
      expect(j['watchedPlaces'], ['place:k1', 'region:Oregon']);
      expect(j['weatherWatch'], {'format': 1, 'here': false, 'regions': ['Oregon'], 'places': ['k1']});
      final s2 = AppSettings(settingsDirOverride: r.dir);
      await s2.init();
      expect(s2.watchedRegions, {'Oregon'});
      expect(s2.watchedSavedPlaces, {'k1'});
      expect(s2.watchHere, isFalse);
      s1.dispose();
      s2.dispose();
    });
    await r.dispose(tester);
  });
}
