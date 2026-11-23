import 'dart:convert';
import 'dart:io';

import 'package:cache/roads/rate_limiter.dart';
import 'package:cache/roads/road_511_def.dart';
import 'package:cache/roads/road_sources.dart';
import 'package:cache/roads/road_state.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/video/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

RoadSourcesFile shipped() => RoadSourcesFile.parse(File('assets/roads/road_sources.json').readAsStringSync());

class _FlakyStore extends MemoryTokenStore {
  /// A keystore that keeps something else than was written.
  @override
  Future<void> write(String key, String value) async => values[key] = key == 'live.key.road511.511.idaho.gov' ? 'wrong' : value;
}

void main() {
  group('the data file', () {
    test('has the 16 confirmed 511 sites, one conditions path per site or none', () {
      final f = shipped();
      expect(f.schema, 1);
      expect(f.version, greaterThanOrEqualTo(1));
      expect(f.sites.length, 16);
      expect(f.siteByHost('511.idaho.gov')!.conditions, 'winterroads');
      expect(f.siteByHost('nvroads.com')!.conditions, 'roadconditions');
      expect(f.siteByHost('511on.ca')!.conditions, 'roadconditions');
      expect(f.siteByHost('drivenc.gov')!.conditions, 'roadconditions');
      expect(f.siteByHost('az511.com')!.conditions, isNull);
      expect(f.siteByHost('manitoba511.ca')!.conditions, isNull, reason: 'ice roads are a different dataset');
      expect([for (final s in f.sites) if (s.conditions != null) s.host].length, 10);
      // New York and Saskatchewan are not 511 sites.
      expect(f.sites.map((s) => s.host), isNot(contains('511ny.org')));
      expect(f.sites.map((s) => s.name), isNot(contains('Saskatchewan')));
    });

    test('names the key row and the stored key per site', () {
      final s = shipped().siteByHost('511.idaho.gov')!;
      expect(s.keyTitle, '511 key (511.idaho.gov)');
      expect(s.keyAlias, 'road511.511.idaho.gov');
      expect(s.rateLimit.calls, 10);
      expect(s.rateLimit.window, const Duration(seconds: 60));
    });

    test('has no feed address and no word "free"', () {
      final text = File('assets/roads/road_sources.json').readAsStringSync();
      expect(RegExp(r'\bfree\b', caseSensitive: false).hasMatch(text), isFalse);
      expect(shipped().checkDownloaded(), isEmpty);
      expect(text, isNot(contains('"url"')));
    });

    test('feeds: usable ones are open or self-serve key, by-request and unverified ones are listed but not usable', () {
      final f = shipped();
      expect(f.feeds.length, 42);
      expect(f.feedById('iddot')!.usable, isTrue);
      expect(f.feedById('ohio')!.usable, isTrue);
      expect(f.feedById('ohio')!.auth!.prefix, 'APIKEY ');
      expect(f.feedById('ptc')!.usable, isFalse);
      expect(f.feedById('ptc')!.byRequest, isTrue);
      expect(f.feedById('mdot_4')!.usable, isFalse);
      expect(f.feedById('txdot_v4_2')!.usable, isFalse);
      expect(f.feedById('cdot_cwz')!.usable, isFalse);
      expect(f.feedById('quebec')!.usable, isFalse);
      expect(f.feedById('mtc')!.rateLimit!.calls, 60);
      expect(f.feedById('mtc')!.rateLimit!.window, const Duration(hours: 1));
      expect(f.feeds.where((x) => x.usable).length, 30);
      expect(f.feeds.where((x) => x.usable && x.access == 'key').length, 5);
    });

    test('a newer copy overrides only when its version is higher and it passes its check', () {
      final base = shipped();
      Map<String, dynamic> copy() => jsonDecode(jsonEncode(base.raw)) as Map<String, dynamic>;
      RoadSourcesFile withVersion(int v, [void Function(Map<String, dynamic>)? edit]) {
        final j = copy()..['version'] = v;
        edit?.call(j);
        return RoadSourcesFile.parse(jsonEncode(j));
      }

      expect(RoadSourcesFile.choose(base, null), same(base));
      expect(RoadSourcesFile.choose(base, withVersion(base.version)), same(base), reason: 'equal versions: the shipped copy');
      expect(RoadSourcesFile.choose(base, withVersion(base.version - 1)), same(base));
      final newer = withVersion(base.version + 1);
      expect(RoadSourcesFile.choose(base, newer), same(newer));

      final lines = <String>[];
      final withUrl = withVersion(base.version + 1, (j) => (j['wzdx'] as Map)['feeds'][0]['url'] = 'https://example.org/feed?token=SECRETVALUE');
      expect(RoadSourcesFile.choose(base, withUrl, onIgnored: lines.add), same(base));
      expect(lines.single, isNot(contains('SECRETVALUE')));
      final noAuth = withVersion(base.version + 1, (j) {
        for (final f in (j['wzdx'] as Map)['feeds'] as List) {
          if (f['id'] == 'cdot') f.remove('auth');
        }
      });
      expect(noAuth.checkDownloaded(), isNotEmpty);
      expect(RoadSourcesFile.choose(base, noAuth), same(base));
      final noKeyPage = withVersion(base.version + 1, (j) => ((j['sites'] as List)[0] as Map)['keyPage'] = '');
      expect(RoadSourcesFile.choose(base, noKeyPage), same(base));
    });

    test('a schema this version does not know is refused', () {
      final j = jsonDecode(File('assets/roads/road_sources.json').readAsStringSync()) as Map<String, dynamic>..['schema'] = 2;
      expect(() => RoadSourcesFile.parse(jsonEncode(j)), throwsFormatException);
      expect(() => RoadSourcesFile.parse('not json'), throwsFormatException);
    });
  });

  group('rate limits', () {
    test('reads the data file wording', () {
      expect(RateLimit.parse('10 calls per 60 seconds')!.window, const Duration(seconds: 60));
      expect(RateLimit.parse('60 requests per hour')!.calls, 60);
      expect(RateLimit.parse('60 requests per hour')!.window, const Duration(hours: 1));
      expect(RateLimit.parse('nonsense'), isNull);
    });

    test('ten calls per 60 seconds per host, shared by everything on the host', () {
      var now = DateTime(2026, 11, 22, 12);
      final l = HostRateLimiter(clock: () => now);
      for (var i = 0; i < 10; i++) {
        expect(l.tryAcquire('511.idaho.gov'), isNull, reason: 'call ${i + 1}');
        now = now.add(const Duration(seconds: 1));
      }
      // the 11th waits until the first leaves the window: it was at :00, now is :10
      final wait = l.tryAcquire('511.idaho.gov')!;
      expect(wait, const Duration(seconds: 50));
      expect(l.used('511.idaho.gov'), 10);
      // another host has its own budget
      expect(l.tryAcquire('511wi.gov'), isNull);
      now = now.add(const Duration(seconds: 50));
      expect(l.tryAcquire('511.idaho.gov'), isNull, reason: 'the first call has left the window');
    });

    test('a call the core answered from its stored copy is given back', () {
      final now = DateTime(2026, 11, 22, 12);
      final l = HostRateLimiter(clock: () => now);
      for (var i = 0; i < 10; i++) {
        expect(l.tryAcquire('h'), isNull);
      }
      expect(l.tryAcquire('h'), isNotNull);
      l.release('h');
      expect(l.used('h'), 9);
      expect(l.tryAcquire('h'), isNull);
    });

    test('SF Bay MTC: 60 requests an hour', () {
      var now = DateTime(2026, 11, 22, 12);
      final l = HostRateLimiter(clock: () => now)..setLimit('wzdx:mtc', shipped().feedById('mtc')!.rateLimit!);
      for (var i = 0; i < 60; i++) {
        expect(l.tryAcquire('wzdx:mtc'), isNull);
        now = now.add(const Duration(seconds: 10));
      }
      expect(l.tryAcquire('wzdx:mtc'), isNotNull);
      now = now.add(const Duration(minutes: 51));
      expect(l.tryAcquire('wzdx:mtc'), isNull);
    });
  });

  group('511 definitions', () {
    final f = shipped();

    test('Idaho keeps the ids and words the assistant already knows, on the one Idaho key', () {
      final ev = road511EventsDef(f.siteByHost('511.idaho.gov')!);
      expect(ev['id'], 'idaho511-events');
      expect(ev['title'], 'Idaho 511 traffic events near the place');
      expect(ev['provider'], 'Idaho Transportation Department (511)');
      expect(ev['api_key'], {'alias': 'road511.511.idaho.gov', 'required': true});
      expect((ev['request'] as Map)['url'], 'https://511.idaho.gov/api/v2/get/event?key={api_key}&format=json');
      final cond = road511ConditionsDef(f.siteByHost('511.idaho.gov')!)!;
      expect(cond['id'], 'idaho511-winter-roads');
      expect((cond['request'] as Map)['url'], 'https://511.idaho.gov/api/v2/get/winterroads?key={api_key}&format=json');
    });

    test('every site gets an events definition on its own host and key; conditions only where the data file names them', () {
      for (final s in f.sites) {
        final ev = road511EventsDef(s);
        expect((ev['request'] as Map)['url'], startsWith('https://${s.host}/api/v2/get/event?key={api_key}'));
        expect((ev['api_key'] as Map)['alias'], 'road511.${s.host}');
        expect(RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch('${ev['id']}'), isTrue, reason: '${ev['id']} is a valid source id');
        final app = ((ev['items'] as List).single as Map)['app'] as Map;
        expect(app.length, lessThanOrEqualTo(8), reason: 'the core allows 8 app names');
        final cond = road511ConditionsDef(s);
        expect(cond == null, s.conditions == null);
        if (cond != null) expect((cond['request'] as Map)['url'], 'https://${s.host}/api/${s.host == '511.idaho.gov' ? 'v2' : 'v3'}/get/${s.conditions}?key={api_key}&format=json');
        if (s.host != '511.idaho.gov') {
          expect(jsonEncode(ev).toLowerCase(), isNot(contains('free')), reason: 'no word "free" outside the published Idaho text');
          if (cond != null) expect(jsonEncode(cond).toLowerCase(), isNot(contains('free')));
        }
      }
    });

    test('a site other than Idaho tolerates a direction of None, a zero planned end and 1 for a full closure', () {
      final ev = road511EventsDef(f.siteByHost('511nl.ca')!);
      final fields = ((ev['items'] as List).single as Map)['fields'] as List;
      Map<dynamic, dynamic> field(String label) => fields.firstWhere((x) => (x as Map)['label'] == label) as Map;
      expect(field('Direction')['omit_if'], containsAll(['unknown', 'none']));
      expect((field('Planned end')['time'] as Map)['not_before'], isNotNull);
      expect((field('All lanes blocked')['lookup'] as Map)['1'], 'yes');
      // Idaho's words stay as published
      final id = road511EventsDef(f.siteByHost('511.idaho.gov')!);
      final idFields = ((id['items'] as List).single as Map)['fields'] as List;
      expect((idFields.firstWhere((x) => (x as Map)['label'] == 'Direction') as Map)['omit_if'], ['unknown']);
    });
  });

  group('the Idaho move', () {
    late Directory dir;
    late AppSettings settings;
    late MemoryTokenStore secrets;
    late RoadSources roads;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('road-migrate');
      settings = AppSettings(settingsDirOverride: dir);
      await settings.init();
      secrets = MemoryTokenStore();
      roads = RoadSources(settings: settings, file: shipped());
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('the key and the sources that are on become the one Idaho 511 source, with no prompt', () async {
      secrets.values['live.key.idaho511'] = 'IDAHO-KEY';
      settings.setLiveSourcesOn({'idaho511-events', 'idaho511-winter-roads', 'wzdx-idaho'}, true);
      expect(await roads.migrateIdaho(secrets), isTrue);
      expect(secrets.values['live.key.road511.511.idaho.gov'], 'IDAHO-KEY');
      expect(secrets.values['live.key.idaho511'], 'IDAHO-KEY', reason: 'the old key is left: an older linked device still uses it');
      expect(roads.records.map((r) => '${r.kind}:${r.id}'), ['k511:511.idaho.gov', 'wzdx:iddot']);
      // the same connector ids as before, so what is on stays on and the assistant's tool is unchanged
      expect(roads.connectors.map((c) => c.id), ['idaho511-events', 'idaho511-winter-roads', 'wzdx-idaho']);
      expect(settings.liveSourcesOn, {'idaho511-events', 'idaho511-winter-roads', 'wzdx-idaho'});
      expect(roads.sources.first.keyAlias, 'road511.511.idaho.gov');
      expect(roads.sources.first.connectors.every((c) => c.keyAlias == 'road511.511.idaho.gov'), isTrue);
      expect(roads.connectors.every((c) => c.rateHost != null || c.id == 'wzdx-idaho'), isTrue);
    });

    test('running it again changes nothing', () async {
      secrets.values['live.key.idaho511'] = 'IDAHO-KEY';
      settings.setLiveSourcesOn({'idaho511-events'}, true);
      expect(await roads.migrateIdaho(secrets), isTrue);
      final records = roads.records.map((r) => r.toJson()).toList();
      final values = Map.of(secrets.values);
      final on = settings.liveSourcesOn;
      expect(await roads.migrateIdaho(secrets), isFalse);
      expect(roads.records.map((r) => r.toJson()).toList(), records);
      expect(secrets.values, values);
      expect(settings.liveSourcesOn, on);
    });

    test('a person with only the Idaho events off and no key gets nothing added', () async {
      expect(await roads.migrateIdaho(secrets), isFalse);
      expect(roads.records, isEmpty);
      expect(secrets.values, isEmpty);
    });

    test('a key alone brings the source with it, switched off', () async {
      secrets.values['live.key.idaho511'] = 'K';
      expect(await roads.migrateIdaho(secrets), isTrue);
      expect(roads.records.single.id, '511.idaho.gov');
      expect(settings.liveSourcesOn, isEmpty);
    });

    test('a new key written is never overwritten by the old one', () async {
      secrets.values['live.key.idaho511'] = 'OLD';
      secrets.values['live.key.road511.511.idaho.gov'] = 'NEW';
      await roads.migrateIdaho(secrets);
      expect(secrets.values['live.key.road511.511.idaho.gov'], 'NEW');
    });

    test('nothing moves when the new key cannot be read back', () async {
      final bad = _FlakyStore()..values['live.key.idaho511'] = 'K';
      settings.setLiveSourcesOn({'idaho511-events'}, true);
      await roads.migrateIdaho(bad);
      expect(roads.records, isEmpty);
    });

    test('an old key name that arrives by sync is the Idaho 511 key', () {
      expect(RoadSources.currentAlias('idaho511'), 'road511.511.idaho.gov');
      expect(RoadSources.currentAlias('firms'), 'firms');
    });
  });
}
