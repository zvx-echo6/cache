// Discover and the setup wizard for review against the approved mockups ("Discover mockups", 2026-11-08), drawn by the app's own
// widgets with Cache's own Discover file and sample device state (no personal data): every mockup frame at 390 x 844 (a phone)
// and 1440 x 900 (a desktop window), light and dark. Frame 9 (the wide store) is frame 3 at 1440.
// flutter test test_shots/discover_renders_test.dart --update-goldens  (pictures in test_shots/discover/)

import 'package:cache/discover/discover_state.dart';
import 'package:cache/discover/ui/activity_page.dart';
import 'package:cache/discover/ui/discover_screen.dart';
import 'package:cache/discover/ui/progress_page.dart';
import 'package:cache/discover/ui/wizard.dart';
import 'package:cache/downloads/download_row.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/weather_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/discover_fakes.dart';
import '../test/support/settings_rig.dart';
import '../test/support/weather_fakes.dart';
import 'shot_kit.dart';

const _out = 'discover';

const Map<String, Size> kSizes = {'390': Size(390, 844), '1440': Size(1440, 900)};

/// The weather Home's card shows in frame 2.
class _Weather extends WeatherState {
  _Weather(SettingsRig r)
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
    temperature: '50 °F',
    conditions: 'partly cloudy',
    high: '58 °F',
    low: '37 °F',
    age: '1 hour old',
    alertsKnown: true,
  );
}

/// A device with nothing on it yet (the wizard's frames).
Future<(FakeDiscoverDevice, DiscoverState)> _fresh() async {
  final dev = FakeDiscoverDevice();
  dev.sizes['region:here'] = 420 << 20;
  final d = await makeDiscover(dev, firstRunDone: false);
  return (dev, d);
}

/// The sample device: Ready added (without the fire feed), a newer Home canning out, the maps for the place; with [backcountry]
/// added too, and with [adding] its downloads part way.
Future<(FakeDiscoverDevice, DiscoverState)> _sample({bool backcountry = false, bool adding = false}) async {
  final dev = FakeDiscoverDevice();
  dev.maps = const [
    MapOffer(id: 'us-id-ada', title: 'Ada County', subtitle: 'Roads and places', bytes: 420 << 20, onDevice: true, home: true),
    MapOffer(id: 'us-id-southwest', title: 'Southwest Idaho', subtitle: 'Roads and places', bytes: 1100 << 20),
  ];
  dev.sizes['region:here'] = 420 << 20;
  dev.present.add('library:usda-2015_en');
  dev.updates.add('library:usda-2015_en');
  dev.settings['home:weather'] = false;
  final d = await makeDiscover(dev);
  final ready = d.catalogue.activity('ready')!;
  d.setLeftOut(ready, 'live:wfigs-incidents-near', true);
  await d.get(ready);
  if (backcountry) await d.get(d.catalogue.activity('backcountry')!);
  if (adding) {
    dev.downloads['library:wikipedia_en_medicine:maxi'] = const DlState(DlPhase.running, done: 620 << 20, total: 1778 << 20, speed: 6.2 * (1 << 20));
    dev.downloads['library:irp.fas.org_en_military-medicine'] = const DlState(DlPhase.waiting, waitingFor: 'Medical encyclopedia');
    dev.downloads['library:outdoors.stackexchange.com_en_all'] = const DlState(DlPhase.waiting, waitingFor: 'Medical encyclopedia');
    dev.downloads['library:zimgit-knots_en'] = const DlState(DlPhase.waiting, waitingFor: 'Medical encyclopedia');
    dev.search['library:irp.fas.org_en_military-medicine'] = 'Waits for its download';
  }
  return (dev, d);
}

Future<void> _settle(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// [page] opened over a page behind it (its back arrow shows), in the app's theme, as the phone or window draws it.
Widget _app(Widget page, CacheThemeId theme, String size) {
  final insets = size == '390' ? const EdgeInsets.only(top: 44, bottom: 30) : EdgeInsets.zero;
  return MaterialApp(
    key: UniqueKey(),
    debugShowCheckedModeBanner: false,
    theme: shotTheme(theme),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(padding: insets, viewPadding: insets),
      child: DefaultTextStyle.merge(style: const TextStyle(fontFamily: 'Roboto'), child: child!),
    ),
    onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    onGenerateInitialRoutes: (_) => [
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      MaterialPageRoute<void>(builder: (_) => page),
    ],
  );
}

Future<void> _shot(WidgetTester tester, String size, CacheThemeId theme, String name, Widget page, {List<String> taps = const []}) async {
  phone(tester, size: kSizes[size]!, ratio: size == '390' ? 2 : 1);
  await tester.pumpWidget(_app(page, theme, size));
  await _settle(tester);
  for (final k in taps) {
    final f = find.byKey(ValueKey(k));
    await tester.ensureVisible(f.first);
    await tester.tap(f.first);
    await _settle(tester);
  }
  await snap(tester, _out, '$size-$name-${theme == CacheThemeId.dark ? 'dark' : 'light'}');
}

void main() {
  setUpAll(loadShotFonts);

  for (final size in kSizes.keys) {
    testWidgets('Discover at $size', (tester) async {
      final rig = await SettingsRig.create(tester);
      final weather = _Weather(rig);
      final layout = LayoutState(settingsDirOverride: rig.dir);
      await tester.runAsync(layout.init);
      for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
        // 1a, 1b, 1c: the wizard's steps 2, 3 and 5 (Ready and Backcountry picked, as the defaults)
        for (final (name, step) in [('1a-wizard-where', 2), ('1b-wizard-activities', 3), ('1c-wizard-summary', 5)]) {
          final (_, d) = await _fresh();
          await _shot(tester, size, theme, name, DiscoverWizard(discover: d, links: const DiscoverLinks(), initialStep: step));
        }
        final (_, fresh) = await _fresh();
        await _shot(tester, size, theme, '1c-wizard-summary-see-everything', DiscoverWizard(discover: fresh, links: const DiscoverLinks(), initialStep: 5, startDetailsOpen: true));

        // Settings' Run setup again: the wizard with what is added now picked (Ready)
        final (_, again) = await _sample();
        await _shot(tester, size, theme, '10-setup-again', DiscoverWizard(discover: again, links: const DiscoverLinks(), initialStep: 3, initialPicked: const {'ready'}, again: true));

        // 2: Home after first run, the Discover card in the Set up card's place
        final (_, home) = await _sample();
        layout.setBlockOn(HomeBlock.shortcuts, false);
        phone(tester, size: kSizes[size]!, ratio: size == '390' ? 2 : 1);
        await tester.pumpWidget(shotApp(
          HomeScreen(layout: layout, weather: weather, discover: home, onOpenDiscover: () {}, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {}),
          theme: theme,
          insets: size == '390' ? const EdgeInsets.only(top: 44, bottom: 30) : EdgeInsets.zero,
        ));
        await _settle(tester);
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await _settle(tester);
        await snap(tester, _out, '$size-2-home-${theme == CacheThemeId.dark ? 'dark' : 'light'}');
        layout.setBlockOn(HomeBlock.shortcuts, true);

        // 3 (and 9 at 1440): the store
        final (_, store) = await _sample();
        await _shot(tester, size, theme, size == '1440' ? '3-9-discover' : '3-discover', DiscoverScreen(discover: store, links: DiscoverLinks(allLibraries: (_) {}, allMaps: (_) {})));

        // 4a, 4b: Backcountry's page and Customize
        final (_, listing) = await _sample();
        final bc = listing.catalogue.activity('backcountry')!;
        await _shot(tester, size, theme, '4a-activity', ActivityPage(discover: listing, activity: bc));
        await _shot(tester, size, theme, '4b-customize', CustomizePage(discover: listing, activity: bc));

        // 5a, 5b: Get, and the same sheet with everything it adds
        await _shot(tester, size, theme, '5a-get', ActivityPage(discover: listing, activity: bc), taps: ['activity-get']);
        await _shot(tester, size, theme, '5b-get-details', ActivityPage(discover: listing, activity: bc), taps: ['activity-get', 'get-details']);

        // 6: adding Backcountry
        final (_, adding) = await _sample(backcountry: true, adding: true);
        await _shot(tester, size, theme, '6-progress', ProgressPage(discover: adding, activities: [adding.catalogue.activity('backcountry')!]));

        // 7: Remove, with its details
        final (_, added) = await _sample(backcountry: true);
        final bc2 = added.catalogue.activity('backcountry')!;
        await _shot(tester, size, theme, '7-remove', ActivityPage(discover: added, activity: bc2), taps: ['activity-added']);
        await _shot(tester, size, theme, '7-remove-details', ActivityPage(discover: added, activity: bc2), taps: ['activity-added', 'remove-details']);

        // 8: Resources, as the Library's Add to Library opens it
        final (_, res) = await _sample();
        await _shot(tester, size, theme, '8-resources', DiscoverScreen(discover: res, face: DiscoverFace.resources, links: DiscoverLinks(allLibraries: (_) {}, allMaps: (_) {}, ownSource: (_) {})));
      }
      await tester.pumpWidget(const SizedBox());
      layout.dispose();
      await rig.dispose(tester);
    });
  }
}
