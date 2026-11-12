import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/video/token_store.dart';
import 'package:cache/weather/alert_notifier.dart';
import 'package:cache/weather/alert_watch.dart';
import 'package:cache/weather/curated.dart';
import 'package:cache/weather/own_source.dart';
import 'package:cache/weather/catalogue_store.dart';
import 'package:cache/weather/live_view.dart' show LiveItem;
import 'package:cache/regions/regions_state.dart';
import 'package:cache/weather/places.dart';
import 'package:cache/weather/weather_state.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';
import 'support/weather_fakes.dart';

/// A key for the sources of your own: it must never show up in a definition or anything the core is told.
const ownSecret = 'SENTINEL-OWN-KEY-5e2b-do-not-leak';

/// The weather part on fakes: no core, no network, files in a temp folder.
class Harness {
  late Directory dir;
  late AppSettings settings;
  late FakeProbe probe;
  late DataPolicy policy;
  late MemoryTokenStore secrets;
  late FakeLiveCore core;
  late FakeWeb web;
  late WeatherState weather;
  Position? here = (lat: 42.54, lon: -113.79);
  DateTime clock = DateTime(2026, 10, 26, 12, 0);
  List<WatchRegion> regions = [];

  Directory get liveDir => Directory('${dir.path}/live-sources');

  static Future<Harness> create({ConnectionKind connection = ConnectionKind.wifi, bool serve = true, bool start = true, Harness? again, DateTime? clock, AlertNotifier? notifier}) async {
    final h = Harness();
    h.notifier = notifier;
    if (clock != null) h.clock = clock;
    h.dir = again?.dir ?? Directory.systemTemp.createTempSync('weather-state');
    h.settings = AppSettings(settingsDirOverride: h.dir);
    await h.settings.init();
    h.probe = FakeProbe(connection);
    h.policy = DataPolicy(settings: h.settings, probe: h.probe);
    h.secrets = again?.secrets ?? MemoryTokenStore();
    h.core = FakeLiveCore(h.liveDir);
    h.web = FakeWeb();
    if (serve) h.web.serve('https://data.cached.info/connectors/', standardCatalogue());
    h.weather = h.build();
    if (start) {
      await h.weather.start();
      while (h.weather.refreshingCatalogues) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
    return h;
  }

  AlertNotifier? notifier;

  WeatherState build() => WeatherState(
    notifier: notifier,
    told: notifier == null ? null : ToldStore(File('${dir.path}/told.json')),
    settings: settings,
    policy: policy,
    core: core,
    secrets: secrets,
    catalogueDir: () async => Directory('${dir.path}/live-catalogues'),
    liveDir: () async => liveDir,
    builtIns: () async => builtInDefinitions(),
    position: () => here,
    regions: () => regions,
    fetch: web.fetch,
    ownFetch: web.tryFetch,
    clock: () => clock,
    hereSettle: hereSettle,
    hereGap: hereGap,
  );

  Duration hereSettle = const Duration(milliseconds: 30);
  Duration hereGap = const Duration(minutes: 15);

  /// The settled end of a restart: the same folder, settings and keys, a new object.
  Future<Harness> restart() async {
    weather.dispose();
    return create(again: this, serve: false);
  }

  Set<String> get inFolder => liveDir.existsSync() ? ({for (final f in liveDir.listSync().whereType<File>()) f.uri.pathSegments.last}..remove('.managed')) : {};

  Map<String, dynamic> get lastPolicy => core.policies.last!;

  bool _gone = false;

  void dispose() {
    if (_gone) return;
    _gone = true;
    weather.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

class FakeNotifier implements AlertNotifier {
  final shown = <NewAlert>[];
  final deliveries = <AlertDelivery>[];
  @override
  Future<bool> show(NewAlert a, AlertDelivery delivery) async {
    if (delivery == AlertDelivery.none) return false;
    shown.add(a);
    deliveries.add(delivery);
    return true;
  }
}

CuratedRow row(String title) => kCurated.firstWhere((r) => r.title == title);

void main() {
  late Harness h;
  tearDown(() => h.dispose());

  group('sources', () {
    test('the catalogue is downloaded at the first start and its sources listed, the built-in ones they replace left out', () async {
      h = await Harness.create();
      final ids = h.weather.sources.map((c) => c.id).toSet();
      expect(ids, containsAll(['openmeteo-forecast', 'nws-alerts-point', 'firms-viirs-near', 'idaho511-events']));
      expect(ids, isNot(contains('weather')), reason: 'replaced by openmeteo-forecast');
      expect(ids, isNot(contains('alerts')), reason: 'replaced by nws-alerts-point');
      expect(h.weather.catalogues.single.catalogue.title, 'Cache connectors');
      expect(h.weather.catalogueErrors, isEmpty);
    });

    test('without a connection the built-in weather and alerts are what there is, and stand in for the curated rows', () async {
      h = await Harness.create(connection: ConnectionKind.none, serve: false);
      expect(h.weather.sources.map((c) => c.id).toSet(), {'weather', 'alerts'});
      expect(h.weather.rowSources(row('Weather forecast')).single.id, 'weather');
      expect(h.weather.rowSources(row('Weather alerts')).single.id, 'alerts');
      expect(h.weather.rowSources(row('Wildfires')), isEmpty);
      expect(h.web.requested, isEmpty, reason: 'nothing is asked while offline');
    });

    test('the sources are not on until the person switches them on, and the core holds only the ones that are on', () async {
      h = await Harness.create();
      expect(h.weather.enabledSources, isEmpty);
      expect(h.inFolder, isEmpty);
      expect((await h.core.sources())['sources'], isEmpty);
      await h.weather.setRowOn(row('Weather forecast'), true);
      expect(h.weather.rowIsOn(row('Weather forecast')), isTrue);
      expect(h.inFolder, {'openmeteo-forecast.json'});
      expect(h.weather.registeredIds, {'openmeteo-forecast'});
      await h.weather.setRowOn(row('Wildfires'), true);
      expect(h.inFolder, containsAll(['wfigs-incidents-near.json', 'wfigs-perimeters-near.json']), reason: 'one switch, both sources');
      await h.weather.setRowOn(row('Weather forecast'), false);
      expect(h.inFolder, isNot(contains('openmeteo-forecast.json')));
    });

    test('a built-in source switched on before the catalogue came is still on when the catalogue replaces it', () async {
      h = await Harness.create(connection: ConnectionKind.none, serve: false);
      await h.weather.setRowOn(row('Weather forecast'), true);
      expect(h.inFolder, contains('weather.json'));
      h.web.serve('https://data.cached.info/connectors/', standardCatalogue());
      h.probe.change(ConnectionKind.wifi);
      await h.weather.refreshCatalogues();
      expect(h.weather.rowIsOn(row('Weather forecast')), isTrue);
      expect(h.inFolder, contains('openmeteo-forecast.json'));
      expect(h.inFolder, isNot(contains('weather.json')));
      expect(h.weather.enabledSources.map((c) => c.id), ['openmeteo-forecast']);
    });

    test('what is on survives a restart, and so do the downloaded sources', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Earthquakes'), true);
      final before = h.web.requested.length;
      h = await h.restart();
      expect(h.weather.isOn('usgs-quakes-near'), isTrue);
      expect(h.weather.sourceById('usgs-quakes-near'), isNotNull, reason: 'kept on the phone');
      expect(h.inFolder, contains('usgs-quakes-near.json'));
      expect(h.web.requested.length, 0, reason: 'a catalogue downloaded less than a day ago is not fetched again ($before at first)');
    });

    test('a catalogue more than a day old is fetched again at start, a newer one is not', () async {
      h = await Harness.create();
      final first = h;
      final later = await Harness.create(again: first, serve: true, clock: first.clock.add(const Duration(days: 2)));
      expect(later.weather.startupRefresh, isNotNull, reason: 'a catalogue two days old is checked at start');
      await later.weather.startupRefresh;
      expect(later.web.requested, isNotEmpty);
      first.weather.dispose();
      h = later;
    });
  });

  group('FEMA IPAWS emergency alerts', () {
    Map<String, String> withIpaws() => buildCatalogue(connectors: [
      entry('nws-alerts-point', 'alerts', 'Weather alerts (NWS, by point)', provider: 'NWS'),
      entry('ipaws-alerts-near', 'alerts', 'Emergency alerts', provider: 'FEMA IPAWS'),
      entry('openmeteo-forecast', 'weather', 'Weather forecast (Open-Meteo)', provider: 'Open-Meteo', coverage: 'worldwide', refresh: 180),
    ]);

    test('go with "Weather alerts" the first time the catalogue offers them; after that the switch is the person\'s', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather alerts'), true);
      expect(h.weather.isOn('ipaws-alerts-near'), isFalse);
      h.web.serve('https://data.cached.info/connectors/', withIpaws());
      await h.weather.refreshCatalogues();
      expect(h.weather.isOn('ipaws-alerts-near'), isTrue);
      expect(h.weather.sourceById('ipaws-alerts-near')!.featured, isTrue, reason: 'a row of its own on the Weather and alerts page');
      await h.weather.setSourceOn(h.weather.sourceById('ipaws-alerts-near')!, false);
      await h.weather.refreshCatalogues();
      expect(h.weather.isOn('ipaws-alerts-near'), isFalse, reason: 'switched off stays off');
      // the curated switches (and the model's list of them) are as before
      expect(kCurated.map((r) => r.title), isNot(contains('Emergency alerts')));
    });

    test('stay off without "Weather alerts", and Turn on weather switches them on with it', () async {
      h = await Harness.create(serve: false);
      h.web.serve('https://data.cached.info/connectors/', withIpaws());
      await h.weather.refreshCatalogues();
      expect(h.weather.isOn('ipaws-alerts-near'), isFalse);
      await h.weather.setRowOn(row('Weather alerts'), true);
      await h.weather.applyAlertDefaults(force: true);
      expect(h.weather.isOn('ipaws-alerts-near'), isTrue);
      expect(h.weather.isOn('nws-alerts-point'), isTrue);
    });
  });

  group('the catalogue is updated, added to and removed from', () {
    test('an update replaces the downloaded definitions: changed, new and gone sources', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Earthquakes'), true);
      final files = buildCatalogue(
        title: 'Cache connectors',
        connectors: [
          entry('usgs-quakes-near', 'earthquakes', 'Earthquakes (USGS), new title', provider: 'USGS', coverage: 'worldwide'),
          entry('brand-new', 'weather', 'Brand new', provider: 'Somebody'),
        ],
      );
      h.web.serve('https://data.cached.info/connectors/', files);
      await h.weather.refreshCatalogues();
      expect(h.weather.sourceById('usgs-quakes-near')!.title, 'Earthquakes (USGS), new title');
      expect(h.weather.sourceById('brand-new'), isNotNull);
      expect(h.weather.sourceById('swpc-kp'), isNull, reason: 'left the catalogue');
      expect(h.inFolder, contains('usgs-quakes-near.json'));
      final text = File('${h.liveDir.path}/usgs-quakes-near.json').readAsStringSync();
      expect(jsonDecode(text)['id'], 'usgs-quakes-near', reason: 'the core gets the definition file as published');
      expect(jsonDecode(text)['title'], 'Earthquakes (USGS), new title');
    });

    test('a bad definition in an update is rejected with its message and the rest are kept', () async {
      h = await Harness.create();
      h.core.invalid.add('swpc-kp');
      await h.weather.refreshCatalogues();
      final c = h.weather.catalogues.single;
      expect(c.skipped['swpc-kp'], contains('items[0].label'));
      expect(h.weather.sourceById('swpc-kp'), isNull);
      expect(h.weather.sourceById('usgs-quakes-near'), isNotNull);
    });

    test('a catalogue that cannot be reached keeps what it had and says why', () async {
      h = await Harness.create();
      h.web.offline = true;
      await h.weather.refreshCatalogues();
      expect(h.weather.sourceById('usgs-quakes-near'), isNotNull);
      expect(h.weather.catalogueErrors.values.single, contains("Couldn't reach"));
    });

    test('catalogue updates use mobile data too (updates always do)', () async {
      h = await Harness.create();
      h.probe.change(ConnectionKind.mobile);
      final before = h.web.requested.length;
      await h.weather.refreshCatalogues();
      expect(h.web.requested.length, greaterThan(before));
      expect(h.weather.catalogueErrors, isEmpty);
    });

    test('an old link from "Add sources from a link" moves to Your own at start: its sources keep their switch and key', () async {
      h = await Harness.create();
      const other = 'https://example.org/c/';
      const link = '${other}catalogue.json';
      h.web.serve(other, buildCatalogue(id: 'friends', title: 'Friends', base: other, connectors: [
        entry('river-x', 'hydrology', 'River X', provider: 'Friends'),
        entry('river-k', 'hydrology', 'River K', provider: 'Friends', keyAlias: 'friendskey'),
        // a source the main list has too stays the main list's
        entry('usgs-quakes-near', 'earthquakes', 'Quakes again', provider: 'Friends'),
      ]));
      // what 1.0.x kept: the link in the settings and its copy in the store
      final kept = await CatalogueLoader(fetch: h.web.fetch, check: (_) async {}).load(link);
      CatalogueStore(Directory('${h.dir.path}/live-catalogues')).save(kept);
      h.settings.addCatalogue(link);
      h.settings.setLiveSourcesOn({'river-x'}, true);
      await h.secrets.write(WeatherState.secretName('friendskey'), ownSecret);
      h = await h.restart();
      expect(h.settings.extraCatalogues, isEmpty, reason: 'the link is gone');
      expect([for (final c in h.weather.ownSources) c.id], ['river-x', 'river-k']);
      expect(h.weather.isOwn(h.weather.sourceById('river-x')!), isTrue);
      expect(h.weather.sourceById('usgs-quakes-near')!.title, isNot('Quakes again'));
      expect(h.weather.isOn('river-x'), isTrue, reason: 'still on');
      expect(h.inFolder, contains('river-x.json'), reason: 'still fetched');
      expect(h.weather.hasKey('friendskey'), isTrue, reason: 'its key still there');
      expect(h.weather.sourceById('river-x')!.featured, isFalse);
      expect(h.weather.catalogues.map((c) => c.url), [kDefaultCatalogueUrl], reason: 'no list of its own any more');
      // and it stays so
      h = await h.restart();
      expect([for (final c in h.weather.ownSources) c.id], ['river-x', 'river-k']);
      expect(h.weather.isOn('river-x'), isTrue);
    });

    test('a link not downloaded yet moves once a refresh brings its copy', () async {
      h = await Harness.create();
      const other = 'https://example.org/c/';
      h.settings.addCatalogue('${other}catalogue.json');
      h.web.serve(other, buildCatalogue(id: 'friends', title: 'Friends', base: other, connectors: [entry('river-x', 'hydrology', 'River X')]));
      await h.weather.refreshCatalogues();
      expect(h.settings.extraCatalogues, isEmpty);
      expect(h.weather.isOwn(h.weather.sourceById('river-x')!), isTrue);
    });

    test('a source made with the form: checked by the core, the key in secure storage only, on, kept across a restart, removed whole', () async {
      h = await Harness.create();
      const d = OwnDraft(name: 'Creek', address: 'https://sensors.example.org/api?lat={lat}&key=$ownSecret', key: ownSecret, refreshMinutes: 60);
      expect(await h.weather.saveOwnSource(d, const []), 'Tick at least one value to show.');
      expect(await h.weather.saveOwnSource(d, const [OwnPick('water.level', 'Water level')]), isNull);
      final c = h.weather.ownSources.single;
      expect(c.id, 'own-creek');
      expect(c.refreshMinutes, 60);
      expect(h.core.checked.last, c.defText);
      expect(c.defText, isNot(contains(ownSecret)));
      expect(c.keyAlias, 'own-creek');
      expect(await h.secrets.read(WeatherState.secretName('own-creek')), ownSecret);
      expect(h.weather.isOn('own-creek'), isTrue);
      expect(h.inFolder, contains('own-creek.json'));
      expect(h.lastPolicy['enabled_sources'], ['own-creek']);
      expect(h.core.everythingSeen(), isNot(contains(ownSecret)));
      // a second one by the same name gets its own id
      expect(await h.weather.saveOwnSource(const OwnDraft(name: 'Creek', address: 'https://other.example.org/x'), const [OwnPick('v', 'V')]), isNull);
      expect([for (final c in h.weather.ownSources) c.id], ['own-creek', 'own-creek-2']);
      h = await h.restart();
      expect(h.weather.sourceById('own-creek'), isNotNull);
      expect(h.weather.hasKey('own-creek'), isTrue);
      expect(h.core.keys['own-creek'], ownSecret);
      // a definition the core refuses is not saved
      h.core.invalid.add('own-bad');
      expect(await h.weather.saveOwnSource(const OwnDraft(name: 'Bad', address: 'https://x.example.org/'), const [OwnPick('v', 'V')]), contains("Cache can't use this source"));
      expect(h.weather.sourceById('own-bad'), isNull);
      await h.weather.removeOwnSource('own-creek');
      expect(h.weather.sourceById('own-creek'), isNull);
      expect(h.weather.isOn('own-creek'), isFalse);
      expect(h.inFolder, isNot(contains('own-creek.json')));
      expect(await h.secrets.read(WeatherState.secretName('own-creek')), isNull);
    });

    test('Try it: offline says so without asking anything; the place and the key are filled in for the request', () async {
      h = await Harness.create();
      const d = OwnDraft(name: 'Creek', address: 'https://sensors.example.org/api?lat={lat}&lon={lon:2}&key=$ownSecret', key: ownSecret);
      h.web.files['https://sensors.example.org/api?lat=42.5400&lon=-113.79&key=$ownSecret'] = utf8.encode('{"water": {"level": 1.42}}');
      final t = await h.weather.tryOwnSource(d);
      expect(t.ok, isTrue);
      expect(t.values.single.path, 'water.level');
      h.probe.change(ConnectionKind.none);
      final asked = h.web.requested.length;
      final off = await h.weather.tryOwnSource(d);
      expect(off.failure, OwnTryFailure.offline);
      expect(h.web.requested.length, asked);
    });

    test('import: one definition, or a list; what is here already or refused is left out with the reason', () async {
      h = await Harness.create();
      final one = await h.weather.previewImport(text: miniDefinition('my-quakes', title: 'My quakes'));
      expect(one.definitions.keys, ['my-quakes']);
      expect(h.weather.sourceById('my-quakes'), isNull, reason: 'nothing kept yet');
      await h.weather.addImported(one);
      expect(h.weather.isOwn(h.weather.sourceById('my-quakes')!), isTrue);
      expect(h.weather.isOn('my-quakes'), isFalse);
      await expectLater(h.weather.previewImport(text: miniDefinition('my-quakes')), throwsA(isA<Exception>().having((e) => '$e', 'text', contains('You have this source already'))));
      await expectLater(h.weather.previewImport(text: miniDefinition('usgs-quakes-near')), throwsA(isA<Exception>().having((e) => '$e', 'text', contains('already'))));
      h.core.invalid.add('broken');
      await expectLater(h.weather.previewImport(text: miniDefinition('broken')), throwsA(isA<Exception>().having((e) => '$e', 'text', contains("Cache can't use this source"))));
      await expectLater(h.weather.previewImport(text: 'hello'), throwsA(isA<Exception>().having((e) => '$e', 'text', contains("isn't a source file"))));
      await expectLater(h.weather.previewImport(text: '{"a": 1}'), throwsA(isA<Exception>().having((e) => '$e', 'text', contains('neither a source nor a list'))));
      const other = 'https://example.org/c/';
      h.web.serve(other, buildCatalogue(id: 'friends', title: 'Friends', base: other, connectors: [entry('river-x', 'hydrology', 'River X'), entry('usgs-quakes-near', 'earthquakes', 'Q'), entry('bad', 'weather', 'Bad')]));
      h.core.invalid.add('bad');
      // the list as a file: its sources are read from the address it gives
      final list = await h.weather.previewImport(text: utf8.decode(h.web.files['${other}catalogue.json']!));
      expect(list.definitions.keys, ['river-x']);
      expect(list.skipped.keys, containsAll(['usgs-quakes-near', 'bad']));
      final byLink = await h.weather.previewImport(link: '${other}catalogue.json');
      expect(byLink.definitions.keys, ['river-x']);
      await h.weather.addImported(byLink);
      expect(h.weather.sourceById('river-x')!.category, 'hydrology', reason: 'what the list says about it is kept');
      expect(h.settings.extraCatalogues, isEmpty);
      await expectLater(h.weather.previewImport(link: 'http://example.org/c.json'), throwsA(isA<Exception>().having((e) => '$e', 'text', contains('https'))));
    });

    test('the main catalogue\'s address can be changed in Advanced, and put back', () async {
      h = await Harness.create();
      const mine = 'https://mine.example.org/c/';
      h.web.serve(mine, buildCatalogue(id: 'mine', title: 'Mine', base: mine, connectors: [entry('my-quakes', 'earthquakes', 'My quakes')]));
      await h.weather.setCatalogueUrl('${mine}catalogue.json');
      expect(h.weather.catalogueUrl, '${mine}catalogue.json');
      expect(h.weather.sourceById('my-quakes'), isNotNull);
      expect(h.weather.sourceById('usgs-quakes-near'), isNull);
      await h.weather.setCatalogueUrl(null);
      expect(h.weather.catalogueUrl, kDefaultCatalogueUrl);
      expect(h.weather.sourceById('usgs-quakes-near'), isNotNull);
    });
  });

  group('the fetch policy', () {
    test('it is pushed at start: online, not metered, mobile data allowed, nothing enabled', () async {
      h = await Harness.create();
      expect(h.lastPolicy, {'online': true, 'allow_metered': true, 'metered': false, 'enabled_sources': <String>[]});
    });

    test('it follows the connection: mobile data, none, Wi-Fi again', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather alerts'), true);
      await Future<void>.delayed(Duration.zero);
      h.probe.change(ConnectionKind.mobile);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.lastPolicy, {'online': true, 'allow_metered': true, 'metered': true, 'enabled_sources': ['nws-alerts-point']});
      h.probe.change(ConnectionKind.none);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.lastPolicy['online'], false);
      h.probe.change(ConnectionKind.wifi);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.lastPolicy, {'online': true, 'allow_metered': true, 'metered': false, 'enabled_sources': ['nws-alerts-point']});
    });

    test('it follows the settings: the sources that are on; mobile data is always allowed for updates', () async {
      h = await Harness.create();
      h.probe.change(ConnectionKind.mobile);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.lastPolicy['allow_metered'], true);
      h.settings.setMobileForDownloads(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.lastPolicy['allow_metered'], true);
      await h.weather.setRowOn(row('Wildfires'), true);
      expect(h.lastPolicy['enabled_sources'], ['wfigs-incidents-near', 'wfigs-perimeters-near']);
    });

    test('the core can never answer "mobile data updates are off": on mobile data the policy always allows it, with no per-source state', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather alerts'), true);
      for (final downloads in [false, true, false]) {
        h.settings.setMobileForDownloads(downloads);
        h.probe.change(ConnectionKind.mobile);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(h.lastPolicy['metered'], true);
        expect(h.lastPolicy['allow_metered'], true, reason: 'metered and not allowed is what makes the core say "mobile data updates are off"');
        expect(h.lastPolicy.containsKey('states'), isFalse, reason: 'no source is put in the metered state by hand');
        h.probe.change(ConnectionKind.wifi);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    test('nothing is pushed twice when nothing changed', () async {
      h = await Harness.create();
      final n = h.core.policies.length;
      h.probe.change(ConnectionKind.wifi);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await h.weather.pushPolicy();
      expect(h.core.policies.length, n);
    });
  });

  group('keys', () {
    const secret = 'SENTINEL-KEY-4c1d9e-do-not-leak';

    test('a key that the provider accepts is saved in secure storage, given to the core, and switches the source on', () async {
      h = await Harness.create();
      final firms = h.weather.sourceById('firms-viirs-near')!;
      expect(h.weather.keyReady(firms), isFalse);
      final r = await h.weather.saveKey(firms, '  $secret  ');
      expect(r.ok, isTrue);
      expect(h.secrets.values[WeatherState.secretName('firms')], secret);
      expect(h.core.keys['firms-viirs-near'], secret, reason: 'memory only in the core');
      expect(h.weather.hasKey('firms'), isTrue);
      expect(h.weather.isOn('firms-viirs-near'), isTrue);
      expect(h.lastPolicy['enabled_sources'], ['firms-viirs-near']);
      // the check was one real download with the key, for a place, storing nothing
      expect(h.core.previews.single['api_key'], secret);
      expect(h.core.previews.single['place'], containsPair('lat', 42.54));
      // and the key is in nothing else the core was told or asked
      expect(h.core.everythingSeen(), isNot(contains(secret)));
      // nor in the settings file, nor in the catalogue folder
      expect(File('${h.dir.path}/preferences.json').readAsStringSync(), isNot(contains(secret)));
    });

    test('a key the provider refuses is not saved, and the words never repeat it', () async {
      h = await Harness.create();
      final firms = h.weather.sourceById('firms-viirs-near')!;
      h.core.previewError = const CacheSearchException('key_missing', 'web search key rejected');
      final r = await h.weather.saveKey(firms, secret);
      expect(r.ok, isFalse);
      expect(r.message, "NASA FIRMS didn't accept this key. Check you copied all of it.");
      expect(r.message, isNot(contains(secret)));
      expect(h.secrets.values, isEmpty);
      expect(h.core.keys['firms-viirs-near'], isNull);
      expect(h.weather.isOn('firms-viirs-near'), isFalse);
      h.core.previewError = const CacheSearchException('fetch_failed', 'HTTP 403: Forbidden');
      expect((await h.weather.saveKey(firms, secret)).message, contains("didn't accept"));
      h.core.previewError = const CacheSearchException('fetch_failed', 'HTTP 503');
      expect((await h.weather.saveKey(firms, secret)).message, contains('had a problem (HTTP 503)'));
      h.core.previewError = const CacheSearchException('fetch_failed', 'Dns: failed');
      expect((await h.weather.saveKey(firms, secret)).message, contains("Couldn't reach NASA FIRMS"));
      h.core.previewError = null;
      h.core.previewResult = {'valid': true, 'mapping_error': {'code': 'bad_response', 'message': 'x'}};
      expect((await h.weather.saveKey(firms, secret)).ok, isFalse);
      expect((await h.weather.saveKey(firms, '   ')).message, 'Paste your key first.');
    });

    test('the saved key is given to the core again at every start', () async {
      h = await Harness.create();
      await h.weather.saveKey(h.weather.sourceById('firms-viirs-near')!, secret);
      h = await h.restart();
      expect(h.core.keys['firms-viirs-near'], secret);
      expect(h.weather.hasKey('firms'), isTrue);
    });

    // 1.1 audit: the app's own fetches (Update now, the background run, "Where I am") send no key; the core uses the one it was
    // handed. Before, the core read that key only for the assistant, and every one of these failed with "needs a key".
    test('a source with a saved key updates from Update now, after a restart and for "Where I am", with no key in the request', () async {
      h = await Harness.create();
      await h.weather.saveKey(h.weather.sourceById('firms-viirs-near')!, secret);
      final r = await h.weather.updateNow();
      expect(r.failures, isEmpty);
      expect(r.fetched, 1);
      expect(h.core.fetches.single['source'], 'firms-viirs-near');
      expect(h.core.fetches.single.containsKey('api_key'), isFalse, reason: 'the core uses the key it was handed');
      expect(h.weather.sourceErrors, isEmpty);
      // a new start (as a background run is): the key is handed over again before anything is fetched
      h = await h.restart();
      expect((await h.weather.updateNow()).failures, isEmpty);
      // "Where I am" moved
      h.here = (lat: 42.70, lon: -113.79);
      h.weather.positionChanged();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect((h.core.fetches.last['place'] as Map)['key'], 'at:42.70,-113.79');
      expect(h.core.everythingSeen(), isNot(contains(secret)));
      // the fake core refuses as the real one does when it holds no key
      h.core.keys.remove('firms-viirs-near');
      expect((await h.weather.updateNow()).failures.single, 'NASA FIRMS for Where I am failed: needs a key');
    });

    test('one key serves every source that uses it', () async {
      h = await Harness.create();
      await h.weather.saveKey(h.weather.sourceById('idaho511-events')!, secret);
      expect(h.core.keys['idaho511-events'], secret);
      expect(h.core.keys['idaho511-winter-roads'], secret);
      expect(h.weather.isOn('idaho511-winter-roads'), isFalse, reason: 'only the one asked for is switched on');
      expect(h.weather.sourcesUsingKey('idaho511').length, 2);
    });

    test('replacing a key does not switch anything on; removing one forgets it everywhere and switches its sources off', () async {
      h = await Harness.create();
      final firms = h.weather.sourceById('firms-viirs-near')!;
      await h.weather.saveKey(firms, secret);
      await h.weather.setSourceOn(firms, false);
      await h.weather.saveKey(firms, '$secret-2', switchOn: false);
      expect(h.weather.isOn('firms-viirs-near'), isFalse);
      expect(h.core.keys['firms-viirs-near'], '$secret-2');
      await h.weather.setSourceOn(firms, true);
      await h.weather.removeKey('firms');
      expect(h.secrets.values, isEmpty);
      expect(h.core.keys['firms-viirs-near'], isNull);
      expect(h.weather.hasKey('firms'), isFalse);
      expect(h.weather.isOn('firms-viirs-near'), isFalse);
    });
  });

  group('places', () {
    test('Where I am is watched until it is unchecked; the choice is kept', () async {
      h = await Harness.create();
      expect(h.settings.watchedPlaces, {'here'});
      h.settings.setWatched('place:cabin', true);
      h.settings.setWatched('here', false);
      final again = AppSettings(settingsDirOverride: h.dir);
      await again.init();
      expect(again.watchedPlaces, {'place:cabin'});
    });

    test('the choices are Where I am, each saved place by name, and the downloaded regions', () async {
      h = await Harness.create();
      h.core.saved = const [SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 44.2, lon: -114.9, label: 'Near Stanley'), SavedPlaceRecord(key: 'work', name: 'Work', lat: 42.5, lon: -113.8)];
      h.regions = const [WatchRegion(name: 'Idaho', lat: 44.4, lon: -114.6)];
      final c = await h.weather.placeChoices();
      expect(c.map((p) => p.id), ['here', 'place:cabin', 'place:work', 'region:Idaho']);
      expect(c[0].subtitle, 'Follows this device');
      expect(c[1].subtitle, 'Near Stanley');
      expect(c[2].subtitle, '42.50, -113.80');
      expect(c[3].subtitle, 'Downloaded region');
      expect(WeatherState.placeRequest(c[0]), {'key': 'at:42.54,-113.79', 'name': 'current location', 'lat': 42.54, 'lon': -113.79});
      expect(WeatherState.placeRequest(c[1])['key'], 'cabin');
      expect(WeatherState.placeRequest(c[3])['key'], 'region-idaho');
    });

    test('Where I am waits for a position; a summary names the first three, one per line, and counts the rest', () async {
      h = await Harness.create();
      h.here = null;
      expect((await h.weather.watchedPlaces()), isEmpty);
      expect((await h.weather.placeChoices()).first.subtitle, contains('position not known yet'));
      h.core.saved = const [
        SavedPlaceRecord(key: 'a', name: 'Home', lat: 42, lon: -113),
        SavedPlaceRecord(key: 'b', name: 'Cabin', lat: 43, lon: -114),
        SavedPlaceRecord(key: 'c', name: 'Work', lat: 44, lon: -115),
      ];
      for (final k in ['a', 'b', 'c']) {
        h.settings.setWatched('place:$k', true);
      }
      expect(await h.weather.watchedSummary(), 'Where I am\nHome\nCabin\n+1 more');
      h.settings.setWatched('here', false);
      expect(await h.weather.watchedSummary(), 'Home\nCabin\nWork');
    });

    test('removing a saved place deletes it in the core and stops watching it; other places cannot be removed', () async {
      h = await Harness.create();
      h.core.saved = const [SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 43, lon: -114)];
      h.settings.setWatched('place:cabin', true);
      final cabin = (await h.weather.placeChoices()).firstWhere((p) => p.id == 'place:cabin');
      await h.weather.removePlace(cabin);
      expect(h.core.deleted, ['cabin']);
      expect(h.settings.watchedPlaces.contains('place:cabin'), isFalse);
      expect((await h.weather.placeChoices()).map((p) => p.id), isNot(contains('place:cabin')));
      await h.weather.removePlace((await h.weather.placeChoices()).first);
      expect(h.core.deleted, ['cabin'], reason: 'Where I am is not a saved place');
    });

    test('regions are the finished map areas by name, at the middle of their areas', () {
      DownloadedArea a(String label, double s, double w, double n, double e, {AreaPhase phase = AreaPhase.done}) => DownloadedArea(
        id: label + s.toString(),
        layerId: 'x',
        bounds: GeoBounds(south: s, west: w, north: n, east: e),
        label: label,
        minZoom: 0,
        maxZoom: 5,
        totalTiles: 1,
        phase: phase,
      );
      final r = watchRegionsOf([
        LocalRegion(id: 'us-id', name: 'Idaho', areas: [a('Idaho', 42, -117, 49, -111), a('Idaho · Hillshade', 42, -117, 49, -111)]),
        LocalRegion(id: 'home', name: 'Home', areas: [a('a label that says nothing', 42.5, -113.8, 42.6, -113.7)]),
        LocalRegion(id: 'us-mt', name: 'Montana', areas: [a('Montana', 44, -116, 49, -104, phase: AreaPhase.running)]),
        LocalRegion(id: 'us-ut', name: 'Utah', routing: const {'state': 'ready'}),
      ]);
      expect(r.map((x) => x.name), ['Home', 'Idaho'], reason: 'named as the region, only with a finished map');
      expect(r.last.lat, 45.5);
      expect(r.last.lon, -114);
      // its whole area, for alerts: the box of its maps (the same box once)
      expect(r.last.boxes, [[-117, 42, -111, 49]]);
      expect(r.last.area!['type'], 'MultiPolygon');
    });
  });

  group('Update now', () {
    Future<void> setUp3(Harness h) async {
      await h.weather.setRowOn(row('Weather forecast'), true);
      await h.weather.setRowOn(row('Weather alerts'), true);
      h.core.saved = const [SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 44.2, lon: -114.9)];
      h.settings.setWatched('place:cabin', true);
    }

    test('fetches every source that is on for every watched place, through the core, with the time', () async {
      h = await Harness.create();
      await setUp3(h);
      final r = await h.weather.updateNow();
      expect(r.ok, isTrue);
      expect(r.fetched, 4);
      expect(h.core.fetches.length, 4);
      expect({for (final f in h.core.fetches) '${f['source']}@${f['place']['key']}'}, {
        'openmeteo-forecast@at:42.54,-113.79',
        'openmeteo-forecast@cabin',
        'nws-alerts-point@at:42.54,-113.79',
        'nws-alerts-point@cabin',
      });
      expect(h.core.fetches.first['now'], matches(RegExp(r'^2026-10-26T12:00:00[+-]\d\d:\d\d$')));
      expect(r.words, 'Updated');
      expect(h.weather.lastOkAt, h.clock);
    });

    // 1.1 audit: "already updating" was only set after the places and the connection were read, so two calls in the same moment
    // (back on the screen and a tap on Update now) both ran: every download twice, and two alert checks.
    test('two updates asked for in the same moment run as one', () async {
      h = await Harness.create();
      await setUp3(h);
      final both = await Future.wait([h.weather.updateNow(), h.weather.updateNow(force: true)]);
      expect([for (final r in both) r.nothingToDo], [null, 'Already updating']);
      expect(h.core.fetches.length, 4, reason: 'every source and place once');
      expect(h.weather.updating, isFalse);
      expect((await h.weather.updateNow()).fetched, 4, reason: 'and the next one runs');
    });

    test('a copy that is still fresh is not downloaded again, and says so', () async {
      h = await Harness.create();
      await setUp3(h);
      h.core.fetchedNew = false;
      final r = await h.weather.updateNow();
      expect(r.fetched, 0);
      expect(r.upToDate, 4);
      expect(r.words, 'Already up to date');
    });

    test("Update now from a person forces a download; the scheduled update keeps the refresh intervals", () async {
      h = await Harness.create();
      await setUp3(h);
      await h.weather.updateNow();
      expect(h.core.fetches.any((f) => f.containsKey('force')), isFalse);
      h.core.fetches.clear();
      await h.weather.updateNow(force: true);
      expect(h.core.fetches.length, 4);
      expect(h.core.fetches.every((f) => f['force'] == true), isTrue);
    });

    test('back on the screen: an update runs only when one is due, without forcing', () async {
      h = await Harness.create();
      expect(await h.weather.updateIfDue(const Duration(minutes: 30)), isNull, reason: 'nothing is switched on');
      await setUp3(h);
      final first = await h.weather.updateIfDue(const Duration(minutes: 30));
      expect(first?.fetched, 4, reason: 'never updated: due');
      expect(h.core.fetches.any((f) => f.containsKey('force')), isFalse);
      h.core.fetches.clear();
      h.clock = h.clock.add(const Duration(minutes: 10));
      expect(await h.weather.updateIfDue(const Duration(minutes: 30)), isNull);
      expect(h.core.fetches, isEmpty);
      h.clock = h.clock.add(const Duration(minutes: 25));
      expect((await h.weather.updateIfDue(const Duration(minutes: 30)))?.fetched, 4);
    });

    test('on mobile data, updates still fetch, also with mobile data downloads off', () async {
      h = await Harness.create();
      await setUp3(h);
      h.settings.setMobileForDownloads(false);
      h.probe.change(ConnectionKind.mobile);
      expect((await h.weather.updateNow()).fetched, 4);
    });

    test('offline: nothing is fetched and it says so', () async {
      h = await Harness.create();
      await setUp3(h);
      h.probe.change(ConnectionKind.none);
      final r = await h.weather.updateNow();
      expect(r.offline, isTrue);
      expect(h.core.fetches, isEmpty);
    });

    test('nothing on, or no place, or a source that needs a key it does not have, is said in words', () async {
      h = await Harness.create();
      expect((await h.weather.updateNow()).words, 'Switch on a source to update it.');
      await h.weather.setRowOn(row('Weather alerts'), true);
      h.settings.setWatched('here', false);
      expect((await h.weather.updateNow()).words, contains('No place is being watched'));
      h.settings.setWatched('here', true);
      h.settings.setLiveSourcesOn({'firms-viirs-near'}, true);
      await h.weather.updateNow();
      expect(h.core.fetches.map((f) => f['source']).toSet(), {'nws-alerts-point'}, reason: 'the keyed source is skipped without its key');
    });

    test('a source that fails is named with its reason; the others still update', () async {
      h = await Harness.create();
      await setUp3(h);
      h.core.fetchErrors['nws-alerts-point'] = const CacheSearchException('fetch_failed', 'HTTP 503: unavailable');
      final r = await h.weather.updateNow();
      expect(r.ok, isFalse);
      expect(r.fetched, 2);
      expect(r.failures.length, 2);
      expect(r.failures.first, 'NWS for Where I am failed: the service answered HTTP 503');
      expect(r.words, startsWith('Updated, but NWS'));
      expect(h.weather.sourceErrors['nws-alerts-point'], 'the service answered HTTP 503');
      h.core.fetchErrors['nws-alerts-point'] = const CacheSearchException('quota', 'limit');
      expect((await h.weather.updateNow()).failures.first, contains('reached its limit for now'));
    });
  });

  group('the status line', () {
    test('nothing on, never updated, fresh, and old: age alone is not a warning', () async {
      h = await Harness.create();
      expect(h.weather.status().headline, 'Nothing switched on yet');
      await h.weather.setRowOn(row('Weather alerts'), true);
      expect(h.weather.status().headline, 'Not updated yet');
      expect(h.weather.status().tone, StatusTone.warn);
      await h.weather.updateNow();
      expect(h.weather.status().headline, 'Updated just now');
      expect(h.weather.status().tone, StatusTone.ok);
      h.clock = h.clock.add(const Duration(minutes: 12));
      expect(h.weather.status().headline, 'Updated 12 min ago');
      // Past the source's refresh time (15 min): the line used to turn into a warning here, between two updates that come
      // about every half hour. Age alone is not a warning: the status line goes by the Weather screen's rule (freshness).
      h.clock = h.clock.add(const Duration(minutes: 20));
      expect(h.weather.status().headline, 'Updated 32 min ago');
      expect(h.weather.status().tone, StatusTone.ok);
      expect((h.weather.status().headline, h.weather.status().tone), (h.weather.freshness().headline, h.weather.freshness().tone));
    });

    test('offline since Friday is the reason beside the age; mobile data never pauses updates', () async {
      h = await Harness.create(clock: DateTime(2026, 10, 23, 9));
      await h.weather.setRowOn(row('Weather alerts'), true);
      await h.weather.updateNow();
      h.probe.change(ConnectionKind.none);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      h.clock = DateTime(2026, 10, 26, 9);
      expect(h.weather.status().headline, 'Updated 3 days ago · No connection since Friday');
      expect(h.weather.status().tone, StatusTone.warn);
      // back online on mobile data: no reason, just old, and the age says so (one rule with the Weather screen's line)
      h.probe.change(ConnectionKind.mobile);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.weather.status().headline, 'Updated 3 days ago');
      expect(h.weather.status().tone, StatusTone.ok);
    });

    test('a failed update shows its reason beside the age', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather alerts'), true);
      await h.weather.setRowOn(row('Earthquakes'), true);
      h.core.fetchErrors['usgs-quakes-near'] = const CacheSearchException('fetch_failed', 'HTTP 500');
      await h.weather.updateNow();
      expect(h.weather.status().headline, 'Updated just now · USGS for Where I am failed: the service answered HTTP 500');
    });

    test('every failing source is in the line, not only the first', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather alerts'), true);
      await h.weather.setRowOn(row('Earthquakes'), true);
      // one that updates, so the line has an age and the failures beside it
      await h.weather.setRowOn(row('Wildfires'), true);
      h.core.fetchErrors['usgs-quakes-near'] = const CacheSearchException('fetch_failed', 'HTTP 500');
      h.core.fetchErrors['nws-alerts-point'] = const CacheSearchException('fetch_failed', 'HTTP 503');
      await h.weather.updateNow();
      final line = h.weather.status().headline;
      expect(line, contains('2 updates failed'));
      expect(line, contains('USGS for Where I am failed'));
      expect(line, contains('NWS for Where I am failed'));
    });

    test('an update writes the definitions of every source that is on first, however it was switched on', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather alerts'), true);
      await h.weather.setRowOn(row('Earthquakes'), true);
      // the folder lost them (a source switched on another way, before its definition was there): the update puts them back
      for (final f in h.liveDir.listSync().whereType<File>()) {
        if (f.path.endsWith('.json')) f.deleteSync();
      }
      expect(h.inFolder, isEmpty);
      await h.weather.updateNow();
      expect(h.inFolder, containsAll(['nws-alerts-point.json', 'usgs-quakes-near.json']));
    });

    test('the age is kept across a restart', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather alerts'), true);
      await h.weather.updateNow();
      h.clock = h.clock.add(const Duration(minutes: 5));
      final c = h.clock;
      h = await h.restart();
      h.clock = c;
      expect(h.weather.status().headline, 'Updated 5 min ago');
      expect(h.weather.settingsLine(), '1 on · Updated 5 min ago');
    });

    test('the Settings line: how many are on and how old', () async {
      h = await Harness.create();
      expect(h.weather.settingsLine(), 'Nothing on');
      await h.weather.setRowOn(row('Weather alerts'), true);
      await h.weather.setRowOn(row('Wildfires'), true);
      expect(h.weather.settingsLine(), '3 on');
    });
  });

  test('what the core holds for a source: the age, and its last problem', () async {
    h = await Harness.create();
    final q = h.weather.sourceById('usgs-quakes-near')!;
    expect((await h.weather.infoFor(q)).age, isNull);
    h.core.stored['usgs-quakes-near'] = {'age': '12 minutes old', 'age_seconds': 720, 'fetched_at': '2026-10-26T11:48:00-06:00', 'expired': false, 'last_error': {'code': 'fetch_failed', 'message': 'HTTP 500'}};
    final i = await h.weather.infoFor(q);
    expect(i.age, '12 minutes old');
    expect(i.lastError, 'HTTP 500');
    expect(i.expired, isFalse);
  });

  group('what the Weather screen and Home show', () {
    Map<String, dynamic> forecast() => {
      'fetched_at': '2026-10-26T11:00:00-06:00',
      'age': '1 hour old',
      'expired': false,
      'items': [
        {'address': 'live:openmeteo-forecast/x/now', 'label': 'Now', 'fields': {'Temperature': '45 °F', 'Conditions': 'clear sky'}},
        {'address': 'live:openmeteo-forecast/x/2026-10-26', 'label': 'Mon 26 Oct', 'fields': {'High': '52 °F', 'Low': '30 °F'}},
      ],
    };

    test('Home: nothing switched on says so', () async {
      h = await Harness.create();
      expect(await homeWeather(h.weather), 'Not set up yet');
      expect(await homeAlerts(h.weather), 'Not set up yet');
    });

    test('after an update, Home never says "Not set up yet" for weather that is on while the weather part is still starting', () async {
      // weather on in 1.0.27; the app updated; the core (and so the weather part) not open yet
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather forecast'), true);
      await h.weather.setRowOn(row('Weather alerts'), true);
      final on = h.settings.liveSourcesOn;
      h.weather.dispose();
      h.settings = AppSettings(settingsDirOverride: h.dir);
      await h.settings.init();
      h.policy = DataPolicy(settings: h.settings, probe: h.probe);
      h.weather = h.build();
      expect(h.settings.liveSourcesOn, on, reason: 'the switches survive the restart');
      expect(h.weather.started, isFalse);
      expect(await homeWeather(h.weather), kWeatherStarting);
      expect(await h.weather.needsTurnOn(), isFalse, reason: 'no Turn on weather button for weather that is on');
      await h.weather.start();
      expect(await homeWeather(h.weather), isNot('Not set up yet'));
      expect(await h.weather.needsTurnOn(), isFalse);
    });

    test('before start with nothing switched on, Home says Not set up yet', () async {
      h = await Harness.create(start: false);
      expect(await homeWeather(h.weather), 'Not set up yet');
      expect(await h.weather.needsTurnOn(), isTrue);
    });

    test('watch areas: Where I am and the downloaded regions, each with its switch (saved places are the Places notebook\'s)', () async {
      h = await Harness.create();
      h.regions = [const WatchRegion(name: 'Idaho', lat: 44.0, lon: -114.7)];
      h.settings.setRegionWatched('Idaho', true);
      final areas = await h.weather.watchAreas();
      expect([for (final a in areas) (a.place.name, a.on)], [('Where I am', true), ('Idaho', true)]);
      h.settings.setWatchHere(false);
      expect([for (final a in await h.weather.watchAreas()) a.on], [false, true]);
    });

    test('Home weather: now, today and the place, with the age', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather forecast'), true);
      h.core.stored['openmeteo-forecast'] = forecast();
      expect(await homeWeather(h.weather), '45 °F, clear sky · High 52 °F, low 30 °F · Where I am · 1 hour old');
    });

    // build 48 on a phone: Home said "no forecast yet" while the Weather screen showed Open-Meteo's forecast, because the first
    // forecast source (NWS current conditions) listed a station with wind and pressure but no temperature.
    Future<Harness> withStations(Map<String, dynamic> stations) async {
      final x = await Harness.create(serve: false);
      x.web.serve('https://data.cached.info/connectors/', buildCatalogue(connectors: [
        entry('nws-observations-latest', 'weather', 'Current conditions (NWS stations)', provider: 'NWS'),
        entry('openmeteo-forecast', 'weather', 'Weather forecast (Open-Meteo)', provider: 'Open-Meteo', coverage: 'worldwide', refresh: 180),
      ]));
      await x.weather.refreshCatalogues();
      await x.weather.setSourcesOn([x.weather.sourceById('nws-observations-latest')!, x.weather.sourceById('openmeteo-forecast')!], true);
      x.core.stored['nws-observations-latest'] = stations;
      return x;
    }

    test('Home weather: a station with no temperature does not hide the forecast after it', () async {
      h = await withStations({
        'age': '3 minutes old',
        'expired': false,
        'items': [
          {'address': 'live:nws-observations-latest/x/KAAA', 'label': 'Conditions at KAAA', 'fields': {'Wind': '5 mph', 'Pressure': '30.1 inHg', 'From the place': '4 mi'}},
          {'address': 'live:nws-observations-latest/x/KBBB', 'label': 'Conditions at KBBB', 'fields': {'Temperature': '48 °F', 'From the place': '19 mi'}},
        ],
      });
      expect(h.weather.enabledSources.first.id, 'nws-observations-latest', reason: 'the stations come first, as on the phone');
      h.core.stored['openmeteo-forecast'] = {
        'age': '1 minute old',
        'expired': false,
        'items': [
          {'address': 'live:openmeteo-forecast/x/now', 'label': 'Now', 'fields': {'Temperature': '50 °F', 'Conditions': 'clear sky'}},
          {'address': 'live:openmeteo-forecast/x/2026-10-26', 'label': 'Mon 26 Oct', 'fields': {'Daytime high': '57 °F', 'Low (early morning)': '33 °F'}},
        ],
      };
      final c = await h.weather.homeCard();
      expect((c.temperature, c.conditions, c.high, c.low, c.age), ('50 °F', 'clear sky', '57 °F', '33 °F', '1 minute old'));
      expect(c.forecastMissing, isFalse);
    });

    test('Home weather: from a list of stations, the nearest one that reports a temperature', () async {
      h = await withStations({
        'age': '3 minutes old',
        'expired': false,
        'items': [
          {'address': 'live:nws-observations-latest/x/KAAA', 'label': 'Conditions at KAAA', 'fields': {'Wind': '5 mph', 'From the place': '4 mi'}},
          {'address': 'live:nws-observations-latest/x/KCCC', 'label': 'Conditions at KCCC', 'fields': {'Temperature': '44 °F', 'Conditions': 'cloudy', 'From the place': '31 mi'}},
          {'address': 'live:nws-observations-latest/x/KBBB', 'label': 'Conditions at KBBB', 'fields': {'Temperature': '48 °F', 'Conditions': 'fair', 'From the place': '19 mi'}},
        ],
      });
      // nothing from Open-Meteo yet: the stations are all there is
      final c = await h.weather.homeCard();
      expect((c.temperature, c.conditions, c.age), ('48 °F', 'fair', '3 minutes old'));
      expect(c.forecastMissing, isFalse);
    });

    test('Home weather: no source with a temperature or conditions still says no forecast yet', () async {
      h = await withStations({
        'age': '3 minutes old',
        'expired': false,
        'items': [
          {'address': 'live:nws-observations-latest/x/KAAA', 'label': 'Conditions at KAAA', 'fields': {'Wind': '5 mph'}},
        ],
      });
      expect((await h.weather.homeCard()).forecastMissing, isTrue);
    });

    // 1.1 audit: a forecast's "Now" lasts 3 hours and the next download can be hours later. Home then took the source's first
    // item ("Tonight", which has neither "Temperature" nor "Conditions") and said "no forecast yet" beside the day's high and low,
    // with 16 days of forecast stored.
    Map<String, dynamic> afterNow() => {
      'fetched_at': '2026-10-26T11:00:00-06:00',
      'age': '4 hours old',
      'expired': false,
      'items': [
        {'address': 'live:openmeteo-forecast/x/tonight', 'label': 'Tonight (Mon Oct 26)', 'time': '2026-10-26T18:00:00-06:00', 'fields': {'Overnight low': '30 °F', 'Worst conditions': 'rain'}},
        {'address': 'live:openmeteo-forecast/x/2026-10-26', 'label': 'Mon Oct 26', 'time': '2026-10-26', 'fields': {'Daytime high': '52 °F', 'Low (early morning)': '30 °F', 'Conditions': 'overcast'}},
        {'address': 'live:openmeteo-forecast/x/2026-10-27', 'label': 'Tue Oct 27', 'time': '2026-10-27', 'fields': {'Daytime high': '60 °F', 'Low (early morning)': '41 °F', 'Conditions': 'clear sky'}},
      ],
    };

    test('Home weather: when "Now" has ended, today\'s forecast under its own label with the age, and no temperature', () async {
      // 15:00 at the place (its times are written at -06:00), whatever this machine's zone
      h = await Harness.create(clock: DateTime.utc(2026, 10, 26, 21));
      await h.weather.setRowOn(row('Weather forecast'), true);
      h.core.stored['openmeteo-forecast'] = afterNow();
      final c = await h.weather.homeCard();
      expect((c.period, c.conditions, c.high, c.low, c.age), ('Mon Oct 26', 'overcast', '52 °F', '30 °F', '4 hours old'));
      expect(c.temperature, isNull, reason: 'a forecast is not a reading: nothing stands in for the temperature that ended');
      expect(c.forecastMissing, isFalse, reason: 'days of forecast are stored');
      expect(c.expired, isFalse);
      // the next day, from the same stored copy: that day's forecast, not the day that has passed
      h.clock = DateTime.utc(2026, 10, 27, 21);
      final next = await h.weather.homeCard();
      expect((next.period, next.conditions, next.high, next.low), ('Tue Oct 27', 'clear sky', '60 °F', '41 °F'));
      // past every day it lists: no day is shown as today
      h.clock = DateTime.utc(2026, 10, 29, 21);
      final past = await h.weather.homeCard();
      expect((past.period, past.conditions), (null, null));
      // and with no item left it is still "no forecast yet"
      h.core.stored['openmeteo-forecast'] = {'fetched_at': '2026-10-26T11:00:00-06:00', 'age': '3 days old', 'expired': false, 'items': <Map<String, dynamic>>[]};
      expect((await h.weather.homeCard()).forecastMissing, isTrue);
    });

    test('Home weather: a day\'s forecast that comes first in the list is not shown as the conditions now', () async {
      // the morning after: "Now" and "Tonight" have both ended, and the day's item comes first
      h = await Harness.create(clock: DateTime.utc(2026, 10, 27, 15));
      await h.weather.setRowOn(row('Weather forecast'), true);
      final f = afterNow();
      (f['items'] as List).removeRange(0, 2);
      f['age'] = '22 hours old';
      h.core.stored['openmeteo-forecast'] = f;
      final c = await h.weather.homeCard();
      expect((c.period, c.conditions, c.high, c.low, c.age), ('Tue Oct 27', 'clear sky', '60 °F', '41 °F', '22 hours old'));
      expect(c.temperature, isNull);
    });

    test('Home weather: a reading still comes first, and a period that has not started is not the one for now', () async {
      h = await Harness.create(clock: DateTime.utc(2026, 10, 26, 21));
      await h.weather.setRowOn(row('Weather forecast'), true);
      final f = afterNow();
      (f['items'] as List).insert(0, {'address': 'live:openmeteo-forecast/x/now', 'label': 'Now', 'time': '2026-10-26T14:45:00-06:00', 'fields': {'Temperature': '45 °F', 'Conditions': 'clear sky'}});
      h.core.stored['openmeteo-forecast'] = f;
      final c = await h.weather.homeCard();
      expect((c.temperature, c.conditions, c.period, c.high, c.low), ('45 °F', 'clear sky', null, '52 °F', '30 °F'));
      // periods with a start time (a forecast written in parts of the day): the one under way, not the one to come
      h.core.stored['openmeteo-forecast'] = {
        'fetched_at': '2026-10-26T11:00:00-06:00',
        'age': '4 hours old',
        'expired': false,
        'items': [
          {'address': 'live:openmeteo-forecast/x/p1', 'label': 'This afternoon', 'time': '2026-10-26T12:00:00-06:00', 'fields': {'Conditions': 'sunny'}},
          {'address': 'live:openmeteo-forecast/x/p2', 'label': 'Tonight', 'time': '2026-10-26T18:00:00-06:00', 'fields': {'Conditions': 'light rain'}},
        ],
      };
      final part = await h.weather.homeCard();
      expect((part.period, part.conditions, part.temperature), ('This afternoon', 'sunny', null));
      h.clock = DateTime.utc(2026, 10, 27, 1); // 19:00 at the place
      expect((await h.weather.homeCard()).period, 'Tonight');
    });

    // Found by reading (weather-screen rebuild): Home took any item of a weather source that has "Temperature" as a reading.
    // NWS by point writes its forecast in 12-hour periods, each with a "Temperature", so with no "Now" from Open-Meteo Home
    // showed tonight's forecast low as the temperature now.
    test('Home weather: a forecast period\'s temperature is never the temperature now', () async {
      // 19:00 at the place (its times are written at -06:00), whatever this machine's zone
      h = await Harness.create(serve: false, clock: DateTime.utc(2026, 10, 27, 1));
      h.web.serve('https://data.cached.info/connectors/', buildCatalogue(connectors: [
        entry('openmeteo-forecast', 'weather', 'Weather forecast (Open-Meteo)', provider: 'Open-Meteo', coverage: 'worldwide', refresh: 180),
        entry('nws-forecast-point', 'weather', 'Weather forecast (NWS, by point)', provider: 'NWS', refresh: 60),
      ]));
      await h.weather.refreshCatalogues();
      await h.weather.setSourcesOn([h.weather.sourceById('openmeteo-forecast')!, h.weather.sourceById('nws-forecast-point')!], true);
      h.core.stored['nws-forecast-point'] = {
        'fetched_at': '2026-10-26T18:40:00-06:00',
        'age': '20 minutes old',
        'expired': false,
        'items': [
          {'address': 'live:nws-forecast-point/x/1', 'label': 'Tonight', 'time': '2026-10-26T18:00-06:00', 'fields': {'Temperature': '31 °F', 'Wind': '5 mph W', 'Summary': 'Mostly Clear'}},
          {'address': 'live:nws-forecast-point/x/2', 'label': 'Tuesday', 'time': '2026-10-27T06:00-06:00', 'fields': {'Temperature': '58 °F', 'Wind': '10 mph SW', 'Summary': 'Sunny'}},
          {'address': 'live:nws-forecast-point/x/3', 'label': 'Tuesday Night', 'time': '2026-10-27T18:00-06:00', 'fields': {'Temperature': '40 °F', 'Wind': '5 mph S', 'Summary': 'Partly Cloudy'}},
        ],
      };
      // nothing from Open-Meteo: the periods are all there is, and none of them is a reading
      final only = await h.weather.homeCard();
      expect(only.temperature, isNull, reason: 'tonight\'s forecast low is not the temperature now');
      // Open-Meteo's "Now" has ended and its days are stored: today's forecast under its own label, as with Open-Meteo alone
      h.core.stored['openmeteo-forecast'] = afterNow();
      final both = await h.weather.homeCard();
      expect(both.temperature, isNull, reason: 'no source holds a reading');
      expect((both.period, both.conditions, both.high, both.low, both.age), ('Mon Oct 26', 'overcast', '52 °F', '30 °F', '4 hours old'));
      // with a "Now" from Open-Meteo, that is the reading
      final f = afterNow();
      (f['items'] as List).insert(0, {'address': 'live:openmeteo-forecast/x/now', 'label': 'Now', 'time': '2026-10-26T18:45:00-06:00', 'fields': {'Temperature': '45 °F', 'Conditions': 'clear sky'}});
      h.core.stored['openmeteo-forecast'] = f;
      final read = await h.weather.homeCard();
      expect((read.temperature, read.conditions, read.period), ('45 °F', 'clear sky', null));
    });

    // Found by reading (weather-screen rebuild): what the app kept of the core's last answer was shown as it was. Updated at
    // 9 PM and opened at 7 AM, Home showed last night's temperature, and that day's high and low, as the weather now until
    // the core answered. A reading stands for three hours (the Weather screen's rule, readingOf), in a kept copy too.
    test('Home weather: a kept "Now" from last night is not the temperature this morning, nor yesterday\'s high and low today\'s', () async {
      // 21:00 at the place (its times are written at -06:00), whatever this machine's zone
      h = await Harness.create(clock: DateTime.utc(2026, 10, 27, 3));
      await h.weather.setRowOn(row('Weather forecast'), true);
      h.core.stored['openmeteo-forecast'] = {
        'fetched_at': '2026-10-26T21:00:00-06:00',
        'age': 'less than a minute old',
        'expired': false,
        'items': [
          {'address': 'live:openmeteo-forecast/x/now', 'label': 'Now', 'time': '2026-10-26T21:00:00-06:00', 'fields': {'Temperature': '41 °F', 'Conditions': 'clear sky'}},
          {'address': 'live:openmeteo-forecast/x/tonight', 'label': 'Tonight (Mon Oct 26)', 'time': '2026-10-26T18:00:00-06:00', 'fields': {'Overnight low': '30 °F', 'Worst conditions': 'clear sky'}},
          {'address': 'live:openmeteo-forecast/x/2026-10-26', 'label': 'Mon Oct 26', 'time': '2026-10-26', 'fields': {'Daytime high': '52 °F', 'Low (early morning)': '30 °F', 'Conditions': 'overcast'}},
          {'address': 'live:openmeteo-forecast/x/2026-10-27', 'label': 'Tue Oct 27', 'time': '2026-10-27', 'fields': {'Daytime high': '60 °F', 'Low (early morning)': '41 °F', 'Conditions': 'light rain'}},
        ],
      };
      final evening = await h.weather.homeCard();
      expect((evening.temperature, evening.conditions, evening.period, evening.high, evening.low), ('41 °F', 'clear sky', null, '52 °F', '30 °F'));
      // still the reading two hours later, from what the app kept
      h.clock = DateTime.utc(2026, 10, 27, 5);
      expect(h.weather.homeCardNow()?.temperature, '41 °F', reason: 'two hours old: it stands');
      // the next start is at 07:00 at the place; the core has not answered yet, so Home has what the app kept
      h.weather.dispose();
      h = await Harness.create(again: h, serve: false, clock: DateTime.utc(2026, 10, 27, 13));
      h.core.busy = Completer<void>();
      final morning = h.weather.homeCardNow()!;
      expect(morning.temperature, isNull, reason: 'last night\'s reading is ten hours old');
      expect((morning.period, morning.conditions, morning.high, morning.low), ('Tue Oct 27', 'light rain', '60 °F', '41 °F'), reason: 'today\'s forecast under its own label, not yesterday\'s high and low');
      expect(morning.age, '10 hours old');
      expect((morning.forecastMissing, morning.expired), (false, false));
      h.core.busy!.complete();
    });

    test('what is kept for Home is not wiped by a later answer with no items', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather forecast'), true);
      h.core.stored['openmeteo-forecast'] = forecast();
      expect(await homeWeather(h.weather), contains('45 °F'));
      h.core.stored['openmeteo-forecast'] = {'age': '4 hours old', 'expired': true, 'items': <Map<String, dynamic>>[], 'last_error': {'code': 'fetch_failed', 'message': 'HTTP 500'}};
      await h.weather.homeCard();
      expect(h.weather.keptViewFor(h.weather.homePlaceNow()!)?.single.items, hasLength(2), reason: 'the last good answer stays');
      expect(h.weather.homeCardNow()?.temperature, '45 °F');
    });

    // Design read: a source that is on without its key is skipped by every update, and the Weather screen said "Not downloaded
    // yet. Update now to get it.", which could never come true.
    test('a source that is on without its key says it needs a key, not that an update will get it', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Wildfires'), true);
      h.settings.setLiveSourcesOn({'firms-viirs-near'}, true);
      await h.weather.sourcesChanged();
      final views = await h.weather.viewFor((await h.weather.watchedPlaces()).single);
      final firms = views.firstWhere((v) => v.source.id == 'firms-viirs-near');
      expect((firms.missing, firms.error), (true, 'needs a key'));
      // a source with nothing downloaded that needs no key (or has it) is as before
      final fires = views.firstWhere((v) => v.source.id == 'wfigs-incidents-near');
      expect((fires.missing, fires.error), (true, null));
      await h.weather.saveKey(h.weather.sourceById('firms-viirs-near')!, 'made-up-key-for-a-test');
      final after = (await h.weather.viewFor((await h.weather.watchedPlaces()).single)).firstWhere((v) => v.source.id == 'firms-viirs-near');
      expect((after.missing, after.error), (true, null));
    });

    // Found by reading (weather-screen rebuild): right after an update had failed for a source with nothing downloaded, the
    // Weather screen's row for it still said "Not downloaded yet. Update now to get it.".
    test('a source whose first download failed says why, not that an update will get it', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Earthquakes'), true);
      h.core.fetchErrors['usgs-quakes-near'] = const CacheSearchException('fetch_failed', 'HTTP 500');
      final r = await h.weather.updateNow();
      expect(r.failures, hasLength(1));
      final failed = (await h.weather.viewFor((await h.weather.watchedPlaces()).single)).single;
      expect((failed.missing, failed.error), (true, 'the service answered HTTP 500'));
      // the next update gets through without bringing anything for the place yet: nothing failed, so it says nothing
      h.core.fetchErrors.clear();
      await h.weather.updateNow();
      final after = (await h.weather.viewFor((await h.weather.watchedPlaces()).single)).single;
      expect((after.missing, after.error), (true, null));
    });

    // Design read: a kept copy said "expired" as of when it was kept, so at a later start data past its time showed as current
    // until the core answered.
    test('what is kept says whether it has expired as of now, not as of when it was kept', () async {
      h = await Harness.create(clock: DateTime.utc(2026, 10, 26, 17)); // 11:00 at the place
      await h.weather.setRowOn(row('Weather forecast'), true);
      await h.weather.setRowOn(row('Weather alerts'), true);
      h.core.stored['openmeteo-forecast'] = {...forecast(), 'valid_until': '2026-10-27T00:00:00-06:00'};
      h.core.stored['nws-alerts-point'] = {'fetched_at': '2026-10-26T10:50:00-06:00', 'valid_until': '2026-10-26T16:50:00-06:00', 'age': '10 minutes old', 'expired': false, 'items': <Map<String, dynamic>>[]};
      final card = await h.weather.homeCard();
      expect((card.expired, card.alertsExpired), (false, false));
      expect(h.weather.homeCardNow()?.expired, isFalse, reason: 'kept, and still inside its time');
      // the next start is two days later; the core has not answered yet
      h.weather.dispose();
      h = await Harness.create(again: h, serve: false, clock: DateTime.utc(2026, 10, 28, 17));
      h.core.busy = Completer<void>();
      final now = h.weather.homeCardNow()!;
      expect((now.expired, now.alertsExpired), (true, true));
      expect([for (final v in h.weather.keptViewFor(h.weather.homePlaceNow()!)!) v.expired], [true, true]);
      h.core.busy!.complete();
    });

    // 1.1 audit: the core answers with an empty list when nothing is active (it leaves out what has ended). That answer did
    // not replace a kept one that had items, so a warning that ended came back at every start until the core answered.
    test('a warning that has ended does not come back from what is kept: an answer with none replaces it', () async {
      h = await Harness.create(clock: DateTime.utc(2026, 10, 26, 16, 30)); // 10:30 at the place
      await h.weather.setRowOn(row('Weather alerts'), true);
      Map<String, dynamic> alerts(List<Map<String, dynamic>> items) => {'fetched_at': '2026-10-26T10:20:00-06:00', 'age': '10 minutes old', 'expired': false, 'items': items};
      final warning = {
        'address': 'live:nws-alerts-point/x/urn:oid:1',
        'label': 'Tornado Warning',
        'time': '2026-10-26T10:00:00-06:00',
        'fields': {'Severity': 'extreme', 'Expires': '2026-10-26 11:00'},
      };
      h.core.stored['nws-alerts-point'] = alerts([warning]);
      expect((await h.weather.homeCard()).alerts.single.label, 'Tornado Warning');
      expect(h.weather.homeCardNow()?.alerts.single.label, 'Tornado Warning', reason: 'kept, and still in force');
      // it ends: the core's answer has no items
      h.clock = DateTime.utc(2026, 10, 26, 17, 30);
      h.core.stored['nws-alerts-point'] = alerts([]);
      expect((await h.weather.homeCard()).alerts, isEmpty);
      expect(h.weather.homeCardNow()?.alerts, isEmpty, reason: 'the answer with none replaced the kept warning');
      expect(h.weather.homeCardNow()?.alertsKnown, isTrue);
      // and at the next start, before the core answers
      h.weather.dispose();
      h = await Harness.create(again: h, serve: false, clock: h.clock);
      h.core.busy = Completer<void>();
      expect(h.weather.homeCardNow()?.alerts, isEmpty);
      h.core.busy!.complete();
    });

    test('a kept warning whose own Expires has passed is not shown at the next start', () async {
      h = await Harness.create(clock: DateTime.utc(2026, 10, 26, 16, 30)); // 10:30 at the place
      await h.weather.setRowOn(row('Weather alerts'), true);
      h.core.stored['nws-alerts-point'] = {
        'fetched_at': '2026-10-26T10:20:00-06:00',
        'age': '10 minutes old',
        'expired': false,
        'items': [
          {'address': 'live:nws-alerts-point/x/urn:oid:1', 'label': 'Tornado Warning', 'time': '2026-10-26T10:00:00-06:00', 'fields': {'Severity': 'extreme', 'Expires': '2026-10-26 11:00'}},
          {'address': 'live:nws-alerts-point/x/urn:oid:2', 'label': 'Flood Watch', 'time': '2026-10-26T09:00:00-06:00', 'fields': {'Severity': 'moderate', 'Expires': '2026-10-27 09:00'}},
        ],
      };
      expect([for (final a in (await h.weather.homeCard()).alerts) a.label], ['Tornado Warning', 'Flood Watch']);
      // the app is closed over the warning's end and opened at 12:00; the core has not answered yet
      h.weather.dispose();
      h = await Harness.create(again: h, serve: false, clock: DateTime.utc(2026, 10, 26, 18));
      h.core.busy = Completer<void>();
      expect([for (final a in h.weather.homeCardNow()!.alerts) a.label], ['Flood Watch'], reason: 'the one still in force stays');
      h.core.busy!.complete();
    });

    test('"Where I am" moving to a new key fetches for it once it settles, at most every 15 minutes', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather forecast'), true);
      h.core.fetches.clear();
      Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 150));
      List<String> hereKeys() => [for (final f in h.core.fetches) '${(f['place'] as Map)['key']}'];
      h.here = (lat: 42.60, lon: -113.79);
      h.weather.positionChanged();
      h.here = (lat: 42.70, lon: -113.79);
      h.weather.positionChanged();
      expect(hereKeys(), isEmpty, reason: 'not before it settles');
      await settle();
      expect(hereKeys(), ['at:42.70,-113.79'], reason: 'one fetch, for where it settled');
      h.here = (lat: 42.80, lon: -113.79);
      h.weather.positionChanged();
      await settle();
      expect(hereKeys(), hasLength(1), reason: 'not again inside the gap');
      h.clock = h.clock.add(const Duration(minutes: 16));
      h.here = (lat: 42.90, lon: -113.79);
      h.weather.positionChanged();
      await settle();
      expect(hereKeys().last, 'at:42.90,-113.79');
      h.probe.kind = ConnectionKind.none;
      h.clock = h.clock.add(const Duration(minutes: 16));
      h.here = (lat: 43.0, lon: -113.79);
      h.weather.positionChanged();
      await settle();
      expect(hereKeys(), hasLength(2), reason: 'nothing while offline');
    });

    test('Home weather: the field names the definition uses now', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather forecast'), true);
      final f = forecast();
      (f['items'] as List)[1] = {
        'address': 'live:openmeteo-forecast/x/2026-10-26',
        'label': 'Mon Oct 26',
        'fields': {'Daytime high': '52 °F', 'Low (early morning)': '30 °F'},
      };
      h.core.stored['openmeteo-forecast'] = f;
      expect(await homeWeather(h.weather), '45 °F, clear sky · High 52 °F, low 30 °F · Where I am · 1 hour old');
    });

    test('Home waits for the position while "Where I am" is ticked, and hears when it arrives', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather forecast'), true);
      await h.weather.setRowOn(row('Wildfires'), true);
      h.here = null;
      expect(h.weather.waitingForPosition, isTrue);
      expect(await homeWeather(h.weather), 'Waiting for your position');
      expect(await homeAlerts(h.weather), 'Waiting for your position');
      expect((await h.weather.updateNow()).words, 'Waiting for your position.');
      var heard = 0;
      h.weather.addListener(() => heard++);
      h.weather.positionChanged();
      expect(heard, 0, reason: 'no position yet: nothing to tell');
      h.here = (lat: 42.54, lon: -113.79);
      h.weather.positionChanged();
      expect(heard, 1, reason: 'the first fix is told');
      h.here = (lat: 42.541, lon: -113.791);
      h.weather.positionChanged();
      expect(heard, 1, reason: 'a move inside the same 0.01 degree key is not');
      h.here = (lat: 42.60, lon: -113.79);
      h.weather.positionChanged();
      expect(heard, 2);
      h.core.stored['openmeteo-forecast'] = forecast();
      expect(await homeWeather(h.weather), contains('Where I am'));
      // Not ticked: Home asks for a place, as before.
      h.here = null;
      h.settings.setWatched('here', false);
      expect(h.weather.waitingForPosition, isFalse);
      expect(await homeWeather(h.weather), 'Choose a place to watch in Settings');
      expect(await homeAlerts(h.weather), 'Choose a place to watch in Settings');
    });

    // build 46: at start Home's card and the Weather screen waited 10-15 s for the core (busy listing PDFs) for data the app
    // already had.
    test('after a restart Home and the Weather screen have the last data and the saved places before the core answers', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather forecast'), true);
      h.core.saved = [const SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 43.1, lon: -114.2)];
      h.core.stored['openmeteo-forecast'] = forecast();
      expect(await homeWeather(h.weather), contains('45 °F'), reason: 'shown once, so kept');
      expect([for (final p in await h.weather.placeChoices()) p.name], containsAll(['Where I am', 'Cabin']));

      h = await h.restart();
      // The new core has nothing yet and is busy: nothing it says arrives.
      h.core.busy = Completer<void>();
      expect([for (final p in h.weather.placeChoicesNow()) p.name], containsAll(['Where I am', 'Cabin']));
      final now = h.weather.homeCardNow();
      expect(now?.temperature, '45 °F');
      expect(now?.place, 'Where I am');
      expect(h.weather.keptViewFor(h.weather.homePlaceNow()!)?.single.items, hasLength(2));
      h.core.busy!.complete();
    });

    test('Update now fetches every source at once and counts each', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather forecast'), true);
      await h.weather.setRowOn(row('Wildfires'), true);
      final r = await h.weather.updateNow();
      expect(r.fetched, h.core.fetches.length);
      expect(h.core.fetches.map((f) => f['source']).toSet(), containsAll(['openmeteo-forecast', 'wfigs-incidents-near']));
    });

    test('Home weather: an expired forecast says it needs a connection', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather forecast'), true);
      h.core.stored['openmeteo-forecast'] = {...forecast(), 'expired': true};
      expect(await homeWeather(h.weather), contains('expired'));
    });

    test('a fire\'s distance is read from the published "From the place" field (else "Distance"), on Home and for pop-ups', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Wildfires'), true);
      h.core.stored['wfigs-incidents-near'] = {
        'age': '20 minutes old',
        'expired': false,
        'items': [
          {'address': 'live:wfigs-incidents-near/x/1', 'label': 'East Fork fire', 'fields': {'Size': '266 acres', 'Contained': '55%', 'From the place': '78 mi'}},
        ],
      };
      final fire = (await h.weather.homeCard()).alerts.single;
      expect(fire.detail, '78 mi · Size 266 acres · Contained 55% · NIFC WFIGS');
      const old = LiveItem(address: 'a', label: 'b', fields: {'Distance': '38 mi S', 'Contained': '5%'});
      expect((old.distance, old.summary, distanceMiles(old)), ('38 mi S', 'Contained 5%', 38.0));
      const now = LiveItem(address: 'a', label: 'b', fields: {'Size': '266 acres', 'From the place': '8 mi'});
      expect((now.distance, now.summary, distanceMiles(now)), ('8 mi', 'Size 266 acres', 8.0), reason: 'a fire within 10 mi is serious');
    });

    test('Home alerts: none active, then a count with the first one', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Wildfires'), true);
      h.core.stored['wfigs-incidents-near'] = {
        'age': '20 minutes old',
        'expired': false,
        'items': [
          {'address': 'live:wfigs-incidents-near/x/none', 'label': 'No active fires', 'none_active': true, 'fields': {}},
        ],
      };
      expect(await homeAlerts(h.weather), 'None active · Where I am · checked 20 minutes old');
      h.core.stored['wfigs-incidents-near'] = {
        'age': '20 minutes old',
        'expired': false,
        'items': [
          {'address': 'live:wfigs-incidents-near/x/1', 'label': 'East Fork fire', 'fields': {'Distance': '38 mi S', 'Contained': '5%'}},
          {'address': 'live:wfigs-incidents-near/x/2', 'label': 'Forleen fire', 'fields': {'Distance': '52 mi W'}},
        ],
      };
      expect(await homeAlerts(h.weather), '2 fires · Where I am');
      await h.weather.setRowOn(row('Weather alerts'), true);
      h.core.stored['nws-alerts-point'] = {
        'age': '5 minutes old',
        'expired': false,
        'items': [
          {'address': 'live:nws-alerts-point/x/1', 'label': 'Red Flag Warning', 'fields': {'Severity': 'severe'}},
        ],
      };
      expect(await homeAlerts(h.weather), '1 warning · 2 fires · Red Flag Warning · Where I am');
      // a fire reported by both the incident and the perimeter source counts once
      await h.weather.setRowOn(row('Weather alerts'), false);
      h.core.stored['wfigs-perimeters-near'] = {
        'age': '20 minutes old',
        'expired': false,
        'items': [
          {'address': 'live:wfigs-perimeters-near/x/1', 'label': 'East Fork fire perimeter', 'fields': {'Distance to fire edge': '38 mi S'}},
        ],
      };
      expect(await homeAlerts(h.weather), '2 fires · Where I am');
      // earthquakes are not counted on Home
      await h.weather.setRowOn(row('Earthquakes'), true);
      h.core.stored['usgs-quakes-near'] = {
        'age': '1 minute old',
        'expired': false,
        'items': [
          {'address': 'live:usgs-quakes-near/x/1', 'label': 'M 2.1 near Hyde Park', 'fields': {'Magnitude': '2.1'}},
        ],
      };
      expect(await homeAlerts(h.weather), '2 fires · Where I am');
      // another watched place's fires are not added in: Home counts the place it names
      h.core.saved = const [SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 43, lon: -114)];
      h.settings.setWatched('place:cabin', true);
      expect((await h.weather.watchedPlaces()).length, 2);
      expect(await homeAlerts(h.weather), '2 fires · Where I am');
      h.settings.setWatched('here', false);
      expect(await homeAlerts(h.weather), '2 fires · Cabin');
    });

    test('the view groups forecasts and alerts, and marks a source with nothing downloaded', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather forecast'), true);
      await h.weather.setRowOn(row('Earthquakes'), true);
      h.core.stored['openmeteo-forecast'] = forecast();
      final p = (await h.weather.watchedPlaces()).single;
      final v = await h.weather.viewFor(p);
      final byId = {for (final x in v) x.source.id: x};
      expect(byId['openmeteo-forecast']!.items.first.fields['Temperature'], '45 °F');
      expect(byId['usgs-quakes-near']!.missing, isTrue);
      expect(byId['usgs-quakes-near']!.error, isNull, reason: 'not downloaded yet is not an error');
    });
  });

  group('alert pop-ups', () {
    Map<String, dynamic> fires(List<String> labels) => {
      'age': '5 minutes old',
      'expired': false,
      'items': [
        for (final l in labels) {'address': 'live:wfigs-incidents-near/x/$l', 'label': l, 'fields': {'Distance': '10 mi N'}},
      ],
    };

    /// "All alerts", so fires pop up too.
    Future<Harness> withNotifier(FakeNotifier n) async {
      final hh = await Harness.create(notifier: n);
      hh.settings.setPopUpFor(PopUpFor.all);
      await hh.weather.setRowOn(row('Wildfires'), true);
      return hh;
    }

    test('Serious only (the default): a severe warning and a fire within 10 mi pop up; a farther fire or an advisory does not, and stays listed', () async {
      final n = FakeNotifier();
      h = await Harness.create(notifier: n);
      expect(h.settings.popUpFor, PopUpFor.serious);
      await h.weather.setRowOn(row('Wildfires'), true);
      await h.weather.setRowOn(row('Weather alerts'), true);
      h.core.stored['wfigs-incidents-near'] = {
        'age': '1 minute old',
        'expired': false,
        'items': [
          {'address': 'live:wfigs-incidents-near/x/near', 'label': 'Rock Creek fire', 'fields': {'Distance': '8 mi SE'}},
          {'address': 'live:wfigs-incidents-near/x/far', 'label': 'East Fork fire', 'fields': {'Distance': '38 mi S'}},
        ],
      };
      h.core.stored['nws-alerts-point'] = {
        'age': '1 minute old',
        'expired': false,
        'items': [
          {'address': 'live:nws/x/1', 'label': 'Red Flag Warning', 'fields': {'Severity': 'severe'}},
          {'address': 'live:nws/x/2', 'label': 'Wind Advisory', 'fields': {'Severity': 'moderate'}},
        ],
      };
      await h.weather.updateNow();
      expect(n.shown.map((a) => a.item.label).toSet(), {'Red Flag Warning', 'Rock Creek fire'});
      expect(n.shown.every((a) => a.serious), isTrue);
      expect(await homeAlerts(h.weather), contains('2 fires'), reason: 'the farther fire is listed'); 
      expect(await homeAlerts(h.weather), contains('Wind Advisory'), reason: 'every alert is listed in Weather either way');
    });

    test('a new fire pops up once; the next update does not repeat it', () async {
      final n = FakeNotifier();
      h = await withNotifier(n);
      h.core.stored['wfigs-incidents-near'] = fires(['East Fork fire']);
      await h.weather.updateNow();
      expect(n.shown.map((a) => a.title), ['East Fork fire near Where I am']);
      expect(n.deliveries.single, AlertDelivery.normal);
      await h.weather.updateNow();
      expect(n.shown.length, 1, reason: 'already told');
      h.core.stored['wfigs-incidents-near'] = fires(['East Fork fire', 'Forleen fire']);
      await h.weather.updateNow();
      expect(n.shown.map((a) => a.item.label), ['East Fork fire', 'Forleen fire']);
    });

    // 1.1 audit: the address of an item at "Where I am" holds the position (rounded to 0.01 degrees) and a fire was known as told
    // by its address only, so the same fire popped up as new each time the phone moved about a kilometre.
    test('a fire told at one position of "Where I am" is not new at the next; it pops up once more when it becomes serious', () async {
      final n = FakeNotifier();
      h = await withNotifier(n);
      Map<String, dynamic> fireAt(String key, String distance, {List<String> more = const []}) => {
        'age': '5 minutes old',
        'expired': false,
        'items': [
          {'address': 'live:wfigs-incidents-near/$key/EF1', 'label': 'East Fork fire', 'fields': {'Distance': distance}},
          for (final m in more) {'address': 'live:wfigs-incidents-near/$key/$m', 'label': m, 'fields': {'Distance': '40 mi W'}},
        ],
      };
      h.core.stored['wfigs-incidents-near'] = fireAt('at:42.54,-113.79', '38 mi S');
      await h.weather.updateNow();
      expect(n.shown.length, 1, reason: 'new');
      expect(n.shown.single.serious, isFalse);
      // the phone moves about a kilometre: the same fire comes under a new address
      h.here = (lat: 42.55, lon: -113.79);
      h.core.stored['wfigs-incidents-near'] = fireAt('at:42.55,-113.79', '37 mi S');
      await h.weather.updateNow();
      expect(n.shown.length, 1, reason: 'the same fire, told already');
      // a drive towards it: within 10 mi it is serious, which it was not when it was told
      h.here = (lat: 42.90, lon: -113.79);
      h.core.stored['wfigs-incidents-near'] = fireAt('at:42.90,-113.79', '8 mi S');
      await h.weather.updateNow();
      expect(n.shown.length, 2, reason: 'serious now: told once more');
      expect(n.shown.last.serious, isTrue);
      h.here = (lat: 42.91, lon: -113.79);
      h.core.stored['wfigs-incidents-near'] = fireAt('at:42.91,-113.79', '7 mi S');
      await h.weather.updateNow();
      expect(n.shown.length, 2, reason: 'told as serious already');
      // a fire not told before is still new there
      h.core.stored['wfigs-incidents-near'] = fireAt('at:42.91,-113.79', '7 mi S', more: ['Forleen fire']);
      await h.weather.updateNow();
      expect(n.shown.map((a) => a.item.label), ['East Fork fire', 'East Fork fire', 'Forleen fire']);
    });

    // Design read: the app worked out how near a fire is from the words of its distance field. For a place inside a fire's mapped
    // edge the words are "inside the area", with no number in them, so the fire had no distance and was never serious: under
    // "Serious only" a fire you stood in did not pop up while one 9 miles away did. The core now gives the number beside the words.
    test('a fire whose edge the place is inside is as near as a fire gets: serious, and it pops up under Serious only', () async {
      LiveItem fire(String words, Map<String, Object>? number) => LiveItem.fromJson({
        'address': 'live:wfigs-perimeters-near/x/1',
        'label': 'Rock Creek fire perimeter',
        'fields': {'From the place': words},
        'distances': ?(number == null ? null : {'From the place': number}),
      });
      final inside = fire('inside the area', {'km': 0.0, 'inside': true});
      expect(distanceMiles(inside), 0);
      expect(isSerious(inside, fire: true), isTrue);
      expect(isSerious(inside, fire: true, fireReachMiles: 1), isTrue, reason: 'inside any reach a place is set to');
      expect(isSerious(fire('at the place', {'km': 0.02, 'inside': false}), fire: true), isTrue);
      expect(distanceMiles(fire('20 km N', {'km': 20.0, 'inside': false})), closeTo(12.43, 0.01));
      expect(isSerious(fire('20 km N', {'km': 20.0, 'inside': false}), fire: true), isFalse);
      expect(distanceMiles(fire('8 mi SE', null)), 8, reason: 'stored before the core gave the number: the words, as before');
      expect(inside.distance, 'inside the area', reason: 'what is shown stays the words');

      final n = FakeNotifier();
      h = await Harness.create(notifier: n);
      expect(h.settings.popUpFor, PopUpFor.serious);
      await h.weather.setRowOn(row('Wildfires'), true);
      h.core.stored['wfigs-incidents-near'] = {
        'age': '1 minute old',
        'expired': false,
        'items': [
          {'address': 'live:wfigs-incidents-near/x/in', 'label': 'Rock Creek fire', 'fields': {'From the place': 'inside the area'}, 'distances': {'From the place': {'km': 0.0, 'inside': true}}},
          {'address': 'live:wfigs-incidents-near/x/far', 'label': 'East Fork fire', 'fields': {'From the place': '38 mi S'}, 'distances': {'From the place': {'km': 61.2, 'inside': false}}},
        ],
      };
      await h.weather.updateNow();
      expect(n.shown.map((a) => a.item.label), ['Rock Creek fire']);
      expect(n.shown.single.serious, isTrue);
    });

    // Design read: one fire source spoke for all, the one with the most items (incidents and their perimeters describe the same
    // fires). With satellite detections on that was the detections: a named fire near the place gave no pop-up and no Home line.
    test('with satellite detections on, a named fire inside reach still pops up, once, and is on Home', () async {
      final n = FakeNotifier();
      h = await Harness.create(notifier: n);
      await h.weather.setRowOn(row('Wildfires'), true);
      await h.weather.saveKey(h.weather.sourceById('firms-viirs-near')!, 'made-up-key-for-a-test');
      Map<String, dynamic> stored(List<Map<String, dynamic>> items) => {'age': '5 minutes old', 'expired': false, 'items': items};
      h.core.stored['firms-viirs-near'] = stored([
        for (var k = 1; k <= 6; k++) {'address': 'live:firms-viirs-near/x/d$k', 'label': 'Satellite fire detection', 'fields': {'From the place': '${40 + k} mi W'}},
      ]);
      h.core.stored['wfigs-incidents-near'] = stored([
        {'address': 'live:wfigs-incidents-near/x/rc', 'label': 'Rock Creek fire', 'fields': {'From the place': '6 mi SE', 'Size': '120 acres'}},
      ]);
      h.core.stored['wfigs-perimeters-near'] = stored([
        {'address': 'live:wfigs-perimeters-near/x/rc-edge', 'label': 'Rock Creek fire perimeter', 'fields': {'Distance to fire edge': '5 mi SE'}},
      ]);
      await h.weather.updateNow();
      expect(n.shown, hasLength(1), reason: 'the named fire, once for its two feeds; the detections 40 miles off are not serious');
      expect(n.shown.single.item.label, startsWith('Rock Creek fire'));
      final card = await h.weather.homeCard();
      expect(card.alerts.where((a) => a.label.startsWith('Rock Creek fire')), hasLength(1), reason: 'one line for the fire two feeds name');
      expect(card.alerts.take(4).any((a) => a.label.startsWith('Rock Creek fire')), isTrue, reason: 'among the lines Home has room for');
      expect(card.alerts.where((a) => a.label == 'Satellite fire detection'), hasLength(6), reason: 'the detections count as themselves');
      // two feeds that write a fire's name differently list it twice: twice is better than not at all
      h.core.stored['wfigs-perimeters-near'] = stored([
        {'address': 'live:wfigs-perimeters-near/x/rc-edge', 'label': 'ROCK CK', 'fields': {'Distance to fire edge': '5 mi SE'}},
      ]);
      expect((await h.weather.homeCard()).alerts.where((a) => !a.label.startsWith('Satellite')).map((a) => a.label).toSet(), {'Rock Creek fire', 'ROCK CK'});
    });

    // 1.1 audit: a check reads what was told, shows, then writes. Two at once both saw a new alert before either had written.
    test('two alert checks at once tell a new fire once', () async {
      final n = FakeNotifier();
      h = await withNotifier(n);
      h.core.stored['wfigs-incidents-near'] = fires(['East Fork fire']);
      await Future.wait([h.weather.checkAlerts(), h.weather.checkAlerts()]);
      expect(n.shown.map((a) => a.item.label), ['East Fork fire']);
    });

    // 1.1 audit: a told list that could not be read was taken as an empty one, so everything in force popped up again. A copy is
    // kept beside it now. Only when neither can be read is it "nothing told": a repeated alert is better than a missed one.
    test('a told list that cannot be read falls back to its copy; with both unreadable what is in force is told once more', () async {
      final n = FakeNotifier();
      h = await withNotifier(n);
      h.core.stored['wfigs-incidents-near'] = fires(['East Fork fire']);
      await h.weather.updateNow();
      expect(n.shown.length, 1);
      final list = File('${h.dir.path}/told.json'), copy = File('${h.dir.path}/told.json.bak');
      Future<void> startAgain() async {
        h.weather.dispose();
        h = await Harness.create(again: h, serve: false, notifier: n);
        h.settings.setPopUpFor(PopUpFor.all);
        h.core.stored['wfigs-incidents-near'] = fires(['East Fork fire']);
      }

      // the list is damaged while the app is closed: the copy kept beside it says what was told
      list.writeAsStringSync('["live:wfigs-inc');
      await startAgain();
      await h.weather.updateNow();
      expect(n.shown.length, 1, reason: 'told before: no repeat');
      // the copy is damaged too: nothing is known of what was told, so what is in force is told again, once
      copy.writeAsStringSync('not a list');
      await startAgain();
      await h.weather.updateNow();
      expect(n.shown.map((a) => a.item.label), ['East Fork fire', 'East Fork fire']);
      expect(jsonDecode(list.readAsStringSync()), contains('live:wfigs-incidents-near/x/East Fork fire'), reason: 'the list is whole again');
      expect(jsonDecode(copy.readAsStringSync()), jsonDecode(list.readAsStringSync()), reason: 'and so is its copy');
      await h.weather.updateNow();
      expect(n.shown.length, 2, reason: 'not a third time');
      // what comes after pops up as usual
      h.core.stored['wfigs-incidents-near'] = fires(['East Fork fire', 'Forleen fire']);
      await h.weather.updateNow();
      expect(n.shown.map((a) => a.item.label), ['East Fork fire', 'East Fork fire', 'Forleen fire']);
    });

    test('alerts already in fresh copies pop up too, once; earthquakes do not', () async {
      final n = FakeNotifier();
      h = await withNotifier(n);
      await h.weather.setRowOn(row('Earthquakes'), true);
      h.core.stored['usgs-quakes-near'] = {
        'age': '1 minute old',
        'expired': false,
        'items': [{'address': 'live:usgs-quakes-near/x/1', 'label': 'M 2.1', 'fields': {}}],
      };
      h.core.fetchedNew = false;
      h.core.stored['wfigs-incidents-near'] = fires(['East Fork fire']);
      await h.weather.updateNow();
      expect(n.shown.map((a) => a.item.label), ['East Fork fire'], reason: 'earthquakes are not pop-ups');
      h.core.fetchedNew = true;
      await h.weather.updateNow();
      expect(n.shown.length, 1, reason: 'already told');
    });

    test('in quiet hours the rest arrive silently; serious ones still ring', () async {
      final n = FakeNotifier();
      h = await withNotifier(n);
      await h.weather.setRowOn(row('Weather alerts'), true);
      h.settings.setQuiet(const QuietHours(on: true, from: 0, to: 23 * 60 + 59));
      h.core.stored['nws-alerts-point'] = {
        'age': '1 minute old',
        'expired': false,
        'items': [
          {'address': 'live:nws/x/1', 'label': 'Flash Flood Warning', 'fields': {'Severity': 'extreme'}},
          {'address': 'live:nws/x/2', 'label': 'Wind Advisory', 'fields': {'Severity': 'moderate'}},
        ],
      };
      await h.weather.updateNow();
      final by = {for (var i = 0; i < n.shown.length; i++) n.shown[i].item.label: n.deliveries[i]};
      expect(by['Flash Flood Warning'], AlertDelivery.normal);
      expect(by['Wind Advisory'], AlertDelivery.silent);
      expect(n.shown.firstWhere((a) => a.item.label == 'Flash Flood Warning').extreme, isTrue);
    });

    test('with None nothing shows, and choosing pop-ups later does not bring back old alerts', () async {
      final n = FakeNotifier();
      h = await withNotifier(n);
      h.settings.setPopUpFor(PopUpFor.none);
      h.core.stored['wfigs-incidents-near'] = fires(['East Fork fire']);
      await h.weather.updateNow();
      expect(n.shown, isEmpty);
      h.settings.setPopUpFor(PopUpFor.all);
      await h.weather.updateNow();
      expect(n.shown, isEmpty);
    });

    test('serious: severe or extreme, an evacuation order always, a fire within the place\'s reach (10 mi by default)', () {
      LiveItem item(String label, Map<String, String> f) => LiveItem(address: 'x', label: label, fields: f);
      expect(isSerious(item('Flood Watch', {}), fire: false, severity: 'moderate'), isFalse);
      expect(isSerious(item('Red Flag Warning', {}), fire: false, severity: 'severe'), isTrue);
      expect(isSerious(item('Evacuation Immediate', {}), fire: false, severity: 'minor'), isTrue);
      expect(isSerious(item('Civil message', {'Event': 'Evacuation order'}), fire: false), isTrue);
      expect(isSerious(item('Rock Creek fire', {'Distance': '8 mi SE'}), fire: true), isTrue);
      expect(isSerious(item('Rock Creek fire', {'Distance': '12 km SE'}), fire: true), isTrue, reason: '7.5 mi');
      expect(isSerious(item('East Fork fire', {'Distance': '38 mi S'}), fire: true), isFalse);
      expect(isSerious(item('East Fork fire', {'Distance': '38 mi S'}), fire: true, fireReachMiles: 50), isTrue, reason: 'a place set farther out');
      expect(isSerious(item('Unknown fire', {}), fire: true), isFalse, reason: 'no distance: listed, not popped up');
    });

    test('a tapped pop-up names its place and item', () {
      const a = '{"place":"place:cabin","address":"live:nws/x/1"}';
      final f = AlertFocus.fromPayload(a);
      expect(f?.placeId, 'place:cabin');
      expect(f?.address, 'live:nws/x/1');
      expect(AlertFocus.fromPayload('not json'), isNull);
    });
  });
}

/// The Home card's weather part as one line, the way the card lays it out.
Future<String> homeWeather(WeatherState w) async {
  final c = await w.homeCard();
  if (c.message != null) return c.message!;
  return [
    [c.temperature, c.conditions].whereType<String>().join(', '),
    if (c.high != null && c.low != null) 'High ${c.high}, low ${c.low}',
    c.place,
    if (c.expired) 'forecast expired' else ?c.age,
  ].join(' · ');
}

/// The Home card's alerts part as one line: the counts, the warnings by name, the place.
Future<String> homeAlerts(WeatherState w) async {
  final c = await w.homeCard();
  if (c.message != null) return c.message!;
  if (!c.alertsKnown) return 'Nothing downloaded yet';
  final fires = c.alerts.where((a) => a.fire).length;
  final warnings = c.alerts.length - fires;
  if (c.alerts.isEmpty) return 'None active · ${c.place} · checked ${c.checked}';
  return [
    if (warnings > 0) warnings == 1 ? '1 warning' : '$warnings warnings',
    if (fires > 0) fires == 1 ? '1 fire' : '$fires fires',
    for (final a in c.alerts) if (!a.fire) a.label,
    c.place,
  ].join(' · ');
}
