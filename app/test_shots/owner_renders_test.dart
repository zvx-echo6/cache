// The 1.0.28 screens for the owner to approve, drawn by the app itself with the owner's 1.0.27 situation as sample data: Idaho
// partly downloaded (places 40%, off-road waiting) with a Forest Service map download stopped, and old per-layer downloads.
// flutter test test_shots/owner_renders_test.dart --update-goldens  (pictures in test_shots/owner/)

import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/guide/guide_book.dart';
import 'package:cache/guide/guide_reader.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/regions/problem_words.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/regions/ui/region_actions.dart';
import 'package:cache/regions/ui/region_page.dart';
import 'package:cache/regions/ui/regions_list_sheet.dart';
import 'package:cache/regions/ui/regions_screen.dart';
import 'package:cache/screens/download_confirm.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/screens/settings/maps_page.dart';
import 'package:cache/screens/setup_card.dart';
import 'package:cache/settings/space.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:cache/weather/weather_state.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/owner_state.dart';
import '../test/support/settings_rig.dart';
import '../test/support/weather_fakes.dart';
import 'shot_kit.dart';

const _out = 'owner';

/// The weather the Home card shows: rain now, with its temperature, and a fire to the north.
class ShotWeather extends WeatherState {
  ShotWeather(SettingsRig r)
    : super(
        settings: r.settings,
        policy: r.policy,
        core: r.liveCore,
        secrets: r.secrets,
        catalogueDir: () async => r.catalogueDir,
        liveDir: () async => r.liveDir,
        builtIns: () async => builtInDefinitions(),
      );

  @override
  Future<bool> needsTurnOn() async => false;

  @override
  Future<HomeWeather> homeCard() async => const HomeWeather(
    place: 'Where I am',
    temperature: '52 °F',
    conditions: 'rain',
    high: '61 °F',
    low: '42 °F',
    age: '3 hours old',
    alertsKnown: true,
    alerts: [HomeAlert(fire: true, label: 'East Fork fire', detail: '78 mi N · 266 acres · 60% contained · National Interagency Fire Center')],
  );
}

Future<void> _pump(WidgetTester tester, OwnerState o, Widget page, {GlobalKey<ScaffoldMessengerState>? messenger}) async {
  await tester.pumpWidget(shotApp(page, messenger: messenger));
  await o.settle(tester);
}

void main() {
  setUpAll(() async {
    await loadShotFonts();
    // "Free up space" in the pop-up opens Settings > Storage (the app's frame sets it).
    openStorageForSpace = (_) {};
  });

  testWidgets('1 and 8: Home with the weather card and Set up Cache (Hide), then Hide with Undo', (tester) async {
    final o = await OwnerState.boot(tester);
    phone(tester);
    final r = o.s;
    final weather = ShotWeather(r);
    // The model as the phone names it once it has been loaded (its own description, as the Models screen shows it).
    final settingsFile = File('${r.dir.path}/settings.json');
    final settings = settingsFile.existsSync() ? (jsonDecode(settingsFile.readAsStringSync()) as Map).cast<String, dynamic>() : <String, dynamic>{};
    settings['names'] = {'gemma-4-E2B-it-Q4_K_M.gguf|3435973837': 'Gemma 4 E2B · Q4_K_M'};
    settingsFile.writeAsStringSync(jsonEncode(settings));
    await tester.runAsync(r.app.init);
    r.app.models = [ModelEntry(path: '${r.modelsDir.path}/gemma-4-E2B-it-Q4_K_M.gguf', size: 3435973837)];
    final zim = '${r.sources.zimsDir!.path}/military_medicine.zim';
    r.sources.zims = [ZimFile(path: zim, size: 1 << 30), ZimFile(path: '${zim}2', size: 1 << 30)];
    r.sources.titles[zim] = 'Military Medicine';
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    final setup = SetupCache(
      app: r.app,
      weather: weather,
      sources: r.sources,
      regions: o.regions,
      browse: r.browse,
      chooseModel: (_) {},
      getArea: (_) {},
      turnOnWeather: (_) {},
      addLibrary: (_) {},
      openGuide: (_, _) {},
    );
    await _pump(tester, o, HomeScreen(layout: layout, setup: setup, weather: weather, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {}));
    await snap(tester, _out, '1-home-weather-and-setup');
    await tester.tap(find.byKey(const ValueKey('setup-hide')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await snap(tester, _out, '8-setup-hidden-undo');
    layout.dispose();
    await o.dispose(tester);
  });

  testWidgets('3, 4 and 5: Settings > Maps, Regions > Local, the Idaho page, the plain error', (tester) async {
    final o = await OwnerState.boot(tester);
    phone(tester);
    await _pump(tester, o, MapsPage(deps: o.s.deps));
    // The page's own one-time note about the duplicates it removed.
    await tester.pump(const Duration(milliseconds: 400));
    await snap(tester, _out, '3-settings-maps');

    await _pump(tester, o, RegionsScreen(regions: o.regions, initialTab: 1));
    await tester.pump(const Duration(seconds: 5));
    await o.settle(tester);
    await snap(tester, _out, '4a-regions-local-stopped');

    // Carry on: the stopped map download goes on; the row shows its bar, labelled.
    final usfs = o.legacy['usfs']!;
    await tester.runAsync(() => o.regions.carryOn('us-id', anyway: true));
    usfs
      ..phase = AreaPhase.running
      ..doneTiles = (usfs.totalTiles * 0.62).round()
      ..bytes = 61 * 1000 * 1000;
    await tester.runAsync(o.regions.refresh);
    await tester.pump();
    await snap(tester, _out, '4b-regions-local-downloading');
    usfs
      ..phase = AreaPhase.failed
      ..interrupted = true
      ..doneTiles = (usfs.totalTiles * 0.4).round()
      ..bytes = 39 * 1000 * 1000;
    await tester.runAsync(o.regions.refresh);

    await _pump(tester, o, RegionPage(regions: o.regions, id: 'us-id'));
    await snap(tester, _out, '4c-region-page-idaho');

    final messenger = GlobalKey<ScaffoldMessengerState>();
    await _pump(tester, o, RegionsScreen(regions: o.regions, initialTab: 1), messenger: messenger);
    tell(
      messenger.currentState!,
      downloadProblemWords(const CacheSearchException('offline', 'HTTP 503 from https://data.cached.info/routing/current.json'), what: 'carry on with Idaho'),
      action: SnackBarAction(label: 'Try again', onPressed: () {}),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await snap(tester, _out, '5-error-snackbar');
    await o.dispose(tester);
  });

  testWidgets('6 and 7: the Regions sheet with sizes at once, and the download pop-up in each case', (tester) async {
    final o = await OwnerState.boot(tester);
    phone(tester);
    await _pump(tester, o, Scaffold(body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => showRegionsSheet(c, o.regions, lat: 42.56, lon: -114.46), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await o.settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await snap(tester, _out, '6-regions-sheet');

    final dir = o.s.dir.path;
    Future<void> popUp(String name, Future<void> Function(BuildContext c) open) async {
      await _pump(tester, o, Scaffold(body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => open(c), child: const Text('open'))))));
      await tester.tap(find.text('open'));
      await o.settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      await snap(tester, _out, name);
    }

    final jerome = o.us['us-id-jerome-county']!;
    final space = Space(free: 103 * 1000 * 1000 * 1000, reserve: 20 * 1000 * 1000 * 1000);
    final newOffer = o.regions.offer(jerome);
    await popUp('7a-popup-new', (c) => confirmDownload(c,
        title: 'Download ${jerome.name}?',
        summary: [partsSentence(map: newOffer.map, routing: newOffer.routing, places: newOffer.places, offroad: newOffer.offroad), sizeWords(newOffer.bytes)],
        bytes: newOffer.bytes,
        name: jerome.name,
        lines: const [],
        space: space));
    final carry = o.regions.offer(o.idaho);
    await popUp('7b-popup-carry-on', (c) => confirmDownload(c,
        title: 'Carry on with Idaho?',
        summary: [if (carry.bytes != null) '${sizeWords(carry.bytes)} to go.', '${sizeWords(carry.already)} is already here.'],
        bytes: carry.bytes,
        name: 'Idaho',
        action: 'Carry on',
        lines: const [],
        space: space));
    final cost = o.regions.costOf(o.idaho);
    await popUp('7c-popup-add-offroad', (c) => confirmDownload(c,
        title: 'Add off-road to Idaho?',
        summary: ['Map, directions and places are already here.', '${sizeWords(cost.offroad)} to download.'],
        bytes: cost.offroad,
        name: 'Idaho',
        lines: const [],
        space: space));
    await popUp('7d-popup-not-enough-space', (c) => confirmDownload(c,
        title: 'Download Idaho?',
        summary: ['Map, directions, places and off-road.', '1.8 GB'],
        bytes: 1800 * 1000 * 1000,
        name: 'Idaho',
        lines: const [],
        space: Space(free: 20900 * 1000 * 1000, reserve: 20 * 1000 * 1000 * 1000)));
    expect(dir, isNotEmpty);
    await o.dispose(tester);
  });

  testWidgets('2: the guide: contents, a section, search', (tester) async {
    phone(tester);
    final book = GuideBook.parse([for (var i = 1; i <= kGuideChapterCount; i++) File('assets/guide/chapters/ch$i.md').readAsStringSync()]);
    await tester.pumpWidget(shotApp(GuideReaderScreen(book: book)));
    await tester.pumpAndSettle();
    await snap(tester, _out, '2a-guide-contents');

    // A section as the guide will show it once its screenshots are placed: the picture, short paragraphs, labels, a link.
    final s = book.byTitle('Cache guide: 1. Getting started: Download a region')!;
    final withShot = s.body.replaceFirst('\n\n1. ', '\n\n![The Regions sheet: each region with its size, and Draw your own area instead](shot:regions-sheet)\n\n1. ');
    final b2 = GuideBook.parse(['# ${s.chapter.heading}\n\n${[for (final x in s.chapter.sections) '## ${x.heading}\n\n${identical(x, s) ? withShot : x.body}'].join('\n\n')}\n']);
    final s2 = b2.byTitle(s.title)!;
    await tester.pumpWidget(shotApp(GuideSectionScreen(book: b2, section: s2)));
    // The picture decodes off the test's clock: wait for it before the picture is taken.
    await tester.runAsync(() => precacheImage(const AssetImage('$kGuideShotsDir/regions-sheet.png'), tester.element(find.byType(GuideSectionScreen))));
    await tester.pumpAndSettle();
    await snap(tester, _out, '2b-guide-section');
    await tester.drag(find.byKey(const ValueKey('guide-section-page')), const Offset(0, -900));
    await tester.pumpAndSettle();
    await snap(tester, _out, '2c-guide-section-lower');

    askCacheInstead = (_) {};
    await tester.pumpWidget(shotApp(GuideReaderScreen(book: book)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('guide-search')), 'storage');
    await tester.pumpAndSettle();
    await snap(tester, _out, '2d-guide-search');
    await tester.enterText(find.byKey(const ValueKey('guide-search')), 'snowmobile trailer hitch');
    await tester.pumpAndSettle();
    await snap(tester, _out, '2e-guide-search-nothing');
    askCacheInstead = null;
  });
}

