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
import 'package:cache/weather/live_view.dart' show LiveItem;
import 'package:cache/regions/regions_state.dart';
import 'package:cache/weather/places.dart';
import 'package:cache/weather/weather_state.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';
import 'support/weather_fakes.dart';

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
    if (serve) h.web.serve('https://cache.echo6.co/connectors/', standardCatalogue());
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
    clock: () => clock,
  );

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
      h.web.serve('https://cache.echo6.co/connectors/', standardCatalogue());
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
      h.web.serve('https://cache.echo6.co/connectors/', withIpaws());
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
      h.web.serve('https://cache.echo6.co/connectors/', withIpaws());
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
      h.web.serve('https://cache.echo6.co/connectors/', files);
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

    test('another catalogue is checked and shown first, then added, and can be removed', () async {
      h = await Harness.create();
      const other = 'https://example.org/c/';
      h.web.serve(other, buildCatalogue(id: 'friends', title: 'Friends catalogue', base: other, connectors: [entry('river-x', 'hydrology', 'River X', provider: 'Friends')]));
      final p = await h.weather.previewCatalogue('${other}catalogue.json');
      expect(p.catalogue.title, 'Friends catalogue');
      expect(p.connectors.single.id, 'river-x');
      expect(h.weather.sourceById('river-x'), isNull, reason: 'nothing is kept until it is added');
      expect(h.settings.extraCatalogues, isEmpty);
      await h.weather.addCatalogue(p);
      expect(h.weather.sourceById('river-x'), isNotNull);
      expect(h.settings.extraCatalogues, ['${other}catalogue.json']);
      await h.weather.setSourceOn(h.weather.sourceById('river-x')!, true);
      expect(h.inFolder, contains('river-x.json'));
      await h.weather.removeCatalogue('${other}catalogue.json');
      expect(h.weather.sourceById('river-x'), isNull);
      expect(h.weather.isOn('river-x'), isFalse);
      expect(h.inFolder, isNot(contains('river-x.json')));
      expect(h.settings.extraCatalogues, isEmpty);
    });

    test('a catalogue where nothing passes the checker, or one already added, is refused with a reason', () async {
      h = await Harness.create();
      const other = 'https://example.org/c/';
      h.web.serve(other, buildCatalogue(id: 'bad', title: 'Bad', base: other, connectors: [entry('x', 'weather', 'X')]));
      h.core.invalid.add('x');
      await expectLater(h.weather.previewCatalogue('${other}catalogue.json'), throwsA(isA<Exception>().having((e) => '$e', 'text', contains('None of the sources'))));
      await expectLater(h.weather.previewCatalogue('https://cache.echo6.co/connectors/catalogue.json'), throwsA(isA<Exception>().having((e) => '$e', 'text', contains('already added'))));
      await expectLater(h.weather.previewCatalogue('http://example.org/c.json'), throwsA(isA<Exception>().having((e) => '$e', 'text', contains('https'))));
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
      expect(c[0].subtitle, 'Follows the phone');
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
    test('nothing on, never updated, fresh, and stale for each reason', () async {
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
      // past the source's refresh time (15 min): old, so the line turns into a warning
      h.clock = h.clock.add(const Duration(minutes: 20));
      expect(h.weather.status().headline, 'Updated 32 min ago');
      expect(h.weather.status().tone, StatusTone.warn);
    });

    test('offline since Friday is the reason beside the age; mobile data never pauses updates', () async {
      h = await Harness.create(clock: DateTime(2026, 10, 23, 9));
      await h.weather.setRowOn(row('Weather alerts'), true);
      await h.weather.updateNow();
      h.probe.change(ConnectionKind.none);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      h.clock = DateTime(2026, 10, 26, 9);
      expect(h.weather.status().headline, 'Updated 3 days ago · No connection since Friday');
      // back online on mobile data: no reason, just old
      h.probe.change(ConnectionKind.mobile);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.weather.status().headline, 'Updated 3 days ago');
      expect(h.weather.status().tone, StatusTone.warn);
    });

    test('a failed update shows its reason beside the age', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather alerts'), true);
      await h.weather.setRowOn(row('Earthquakes'), true);
      h.core.fetchErrors['usgs-quakes-near'] = const CacheSearchException('fetch_failed', 'HTTP 500');
      await h.weather.updateNow();
      expect(h.weather.status().headline, 'Updated just now · USGS for Where I am failed: the service answered HTTP 500');
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

    test('Home weather: now, today and the place, with the age', () async {
      h = await Harness.create();
      await h.weather.setRowOn(row('Weather forecast'), true);
      h.core.stored['openmeteo-forecast'] = forecast();
      expect(await homeWeather(h.weather), '45 °F, clear sky · High 52 °F, low 30 °F · Where I am · 1 hour old');
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
