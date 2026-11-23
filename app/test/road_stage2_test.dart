import 'dart:convert';
import 'dart:io';

import 'package:cache/roads/credential_strip.dart';
import 'package:cache/roads/road_dedupe.dart';
import 'package:cache/roads/road_event.dart';
import 'package:cache/roads/road_geo.dart';
import 'package:cache/roads/road_registry.dart';
import 'package:cache/roads/road_sources.dart';
import 'package:cache/roads/road_state.dart';
import 'package:cache/roads/wzdx_def.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

RoadSourcesFile shipped() => RoadSourcesFile.parse(File('assets/roads/road_sources.json').readAsStringSync());

RoadEvent ev(
  String id,
  RoadEventSource source,
  List<LL> line, {
  RoadEventKind kind = RoadEventKind.work,
  int? start,
  int? end,
}) => RoadEvent(id: id, source: source, sourceId: source == RoadEventSource.event511 ? 'idaho511-events' : 'wzdx-idaho', kind: kind, road: 'I-84', line: line.length > 1 ? line : const [], point: line.first, startUnix: start, endUnix: end);

/// A straight line of [n] points from [from] going east, [stepM] metres apart.
List<LL> eastLine(LL from, int n, double stepM) {
  const mPerDegLon = 111320.0 * 0.7237; // cos(43.6 deg)
  return [for (var i = 0; i < n; i++) LL(from.lat, from.lon + i * stepM / mPerDegLon)];
}

void main() {
  const boise = LL(43.6, -116.28);

  group('credential stripping', () {
    test('removes every query parameter that is a key or a token, and what is before the host', () {
      for (final name in ['key', 'api_key', 'apiKey', 'api-key', 'app_key', 'token', 'access_token', 'subscription-key', 'secret', 'password', 'auth']) {
        final s = stripCredentials('https://example.org/wzdx?state=ID&$name=SENTINEL-VALUE&format=json');
        expect(s.url, 'https://example.org/wzdx?state=ID&format=json', reason: name);
        expect(s.removed, isTrue, reason: name);
        expect(s.url, isNot(contains('SENTINEL')));
      }
      final u = stripCredentials('https://user:pw-SENTINEL@example.org/feed#frag');
      expect(u.url, 'https://example.org/feed');
      expect(u.removed, isTrue);
    });

    test('an address with no credential is unchanged and says so', () {
      final s = stripCredentials('https://511.idaho.gov/api/wzdx');
      expect(s.url, 'https://511.idaho.gov/api/wzdx');
      expect(s.removed, isFalse);
      expect(stripCredentials('https://x.org/a?b=1&c=2').url, 'https://x.org/a?b=1&c=2');
    });

    test('only https with a host is an address', () {
      for (final bad in ['http://example.org/feed', 'ftp://example.org', 'example.org/feed', '', 'https://']) {
        expect(stripCredentials(bad).valid, isFalse, reason: bad);
      }
    }, skip: false);

    test('the log line has no query', () {
      expect(addressForLog('https://example.org/wzdx?token=SENTINEL'), 'example.org/wzdx');
    });

    test('a registry row with a token inline is stored without it, and the person sees the same words', () {
      final rows = jsonEncode([
        {'feedname': 'odot', 'url': 'https://example.org/wzdx?access_token=SENTINEL-TOKEN&state=OK', 'version': '4', 'active': 'yes'},
        {'feedname': 'vdot', 'url': {'url': 'https://example.org/v?token=SENTINEL-2'}, 'version': '4'},
        {'feedname': 'iddot', 'url': 'https://511.idaho.gov/api/wzdx', 'version': '4.1'},
        {'feedname': 'gone', 'url': 'https://example.org/x', 'active': 'no'},
        {'feedname': 'plain', 'url': 'http://example.org/insecure'},
        {'url': 'https://example.org/nameless'},
      ]);
      final reg = RoadRegistry.parse(rows);
      expect(reg.feed('odot')!.url, 'https://example.org/wzdx?state=OK');
      expect(reg.feed('odot')!.removedCredential, isTrue);
      expect(reg.feed('vdot')!.url, 'https://example.org/v');
      expect(reg.feed('iddot')!.removedCredential, isFalse);
      expect(reg.feed('gone')!.active, isFalse);
      expect(reg.feed('plain')!.hasAddress, isFalse);
      expect(reg.feeds.length, 5);
      // nothing the registry gives out has a sentinel in it
      final all = reg.feeds.values.map((f) => '${f.id} ${f.url} ${f.version} ${f.state} ${f.organization}').join('\n');
      expect(all, isNot(contains('SENTINEL')));
      expect(() => RoadRegistry.parse('nope'), throwsFormatException);
    });

    test('a pasted address is stripped and says so without repeating the value', () {
      final p = readPastedFeed('https://example.org/feed?api_key=SENTINEL&x=1');
      expect(p.ok, isTrue);
      expect(p.url, 'https://example.org/feed?x=1');
      expect(p.note, 'Any key in the address was removed. Add your key in Settings > API keys.');
      expect(p.note, isNot(contains('SENTINEL')));
      expect(readPastedFeed('https://example.org/feed').note, isNull);
      expect(readPastedFeed('http://example.org/feed').problem, 'Enter an address that starts with https://');
    });
  });

  group('adding WZDx feeds', () {
    late Directory dir;
    late AppSettings settings;
    late RoadSources roads;
    final registry = RoadRegistry.parse(jsonEncode([
      {'feedname': 'iddot', 'url': 'https://511.idaho.gov/api/wzdx', 'version': '4.1'},
      {'feedname': 'ohio', 'url': 'https://example.org/ohio?api-key=SENTINEL-OHIO', 'version': '4.2'},
      {'feedname': 'ptc', 'url': 'https://example.org/ptc?api_key=SENTINEL-PTC', 'version': '4.1'},
      {'feedname': 'txdot_v4_2', 'url': 'https://example.org/tx?key=SENTINEL-TX', 'version': '4.2'},
      {'feedname': 'cdot_cwz', 'url': 'https://example.org/cwz', 'version': 'CWZ 1.0'},
    ]));

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('road-feeds');
      settings = AppSettings(settingsDirOverride: dir);
      await settings.init();
      roads = RoadSources(settings: settings, file: shipped());
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('open and self-serve key feeds are added; by-request, unverified and unsupported ones are not', () {
      final f = shipped();
      expect(roads.addRegistryFeed(f.feedById('iddot')!, registry), AddFeedResult.added);
      expect(roads.addRegistryFeed(f.feedById('iddot')!, registry), AddFeedResult.already);
      expect(roads.addRegistryFeed(f.feedById('ohio')!, registry), AddFeedResult.added);
      expect(roads.addRegistryFeed(f.feedById('ptc')!, registry), AddFeedResult.notUsable, reason: 'by request from the publisher');
      expect(roads.addRegistryFeed(f.feedById('txdot_v4_2')!, registry), AddFeedResult.notUsable, reason: 'key instructions not verified');
      expect(roads.addRegistryFeed(f.feedById('cdot_cwz')!, registry), AddFeedResult.notUsable, reason: 'Connected Work Zones 1.0');
      expect(roads.addRegistryFeed(f.feedById('mcdot')!, registry), AddFeedResult.noAddress, reason: 'the registry has no row for it');
      expect(roads.records.map((r) => r.id), ['iddot', 'ohio']);
    });

    test('nothing stored, defined, listed or logged has a publisher token in it', () {
      roads.addRegistryFeed(shipped().feedById('ohio')!, registry);
      roads.addPastedFeed('https://example.org/own?token=SENTINEL-PASTED&state=ID', name: 'My feed');
      expect(jsonEncode(settings.roadSources), isNot(contains('SENTINEL')));
      for (final c in roads.connectors) {
        expect(c.defText, isNot(contains('SENTINEL')));
        expect(c.defText, isNot(contains('token=')));
      }
      expect(File('${dir.path}/preferences.json').readAsStringSync(), isNot(contains('SENTINEL')));
    });

    test('a keyed feed takes the person\'s own key where the feed says, under its own key row', () {
      roads.addRegistryFeed(shipped().feedById('ohio')!, registry);
      final src = roads.sources.single;
      expect(src.keyTitle, 'WZDx key (Ohio DOT)');
      expect(src.keyAlias, 'wzdx.ohio');
      final def = jsonDecode(src.connectors.single.defText) as Map<String, dynamic>;
      expect((def['request'] as Map)['headers'], {'Authorization': 'APIKEY {api_key}'});
      expect((def['request'] as Map)['url'], 'https://example.org/ohio');
      expect(def['api_key'], {'alias': 'wzdx.ohio', 'required': true});
    });

    test('a query key feed gets {api_key} in its address; an open feed has no key at all', () {
      final f = shipped();
      final spec = WzdxSpec(id: 'wzdx-ncdot', title: 't', provider: 'p', area: 'a', url: 'https://www.drivenc.gov/api/wzdx', auth: f.feedById('ncdot')!.auth, keyAlias: 'wzdx.ncdot');
      expect(wzdxRequestUrl(spec), 'https://www.drivenc.gov/api/wzdx?key={api_key}');
      final withQuery = WzdxSpec(id: 'x', title: 't', provider: 'p', area: 'a', url: 'https://x.org/f?state=ID', auth: f.feedById('cdot')!.auth, keyAlias: 'wzdx.cdot');
      expect(wzdxRequestUrl(withQuery), 'https://x.org/f?state=ID&apiKey={api_key}');
      roads.addRegistryFeed(f.feedById('iddot')!, registry);
      final def = jsonDecode(roads.sources.single.connectors.single.defText) as Map<String, dynamic>;
      expect(def.containsKey('api_key'), isFalse);
      expect(def['id'], 'wzdx-idaho');
    });

    test('a pasted feed is a source of its own with no key', () {
      final r = roads.addPastedFeed('https://example.org/feed?apikey=SENTINEL', name: 'Mine')!;
      expect(r.id, startsWith('custom-'));
      expect(r.url, 'https://example.org/feed');
      final src = roads.sources.single;
      expect(src.title, 'WZDx road work: Mine');
      expect(src.keyAlias, isNull);
      expect(roads.addPastedFeed('http://example.org/feed'), isNull);
      // the same address again is the same source
      roads.addPastedFeed('https://example.org/feed?token=OTHER');
      expect(roads.records.length, 1);
    });

    test('the picker lists the usable feeds that have an address, and the registry address list comes from the registry', () {
      final names = addableFeeds(shipped(), registry).map((f) => f.id);
      expect(names, containsAll(['iddot', 'ohio']));
      expect(names, isNot(contains('ptc')));
      expect(names, isNot(contains('txdot_v4_2')));
    });

    test('feed refresh is the publisher\'s rate, never under 30 minutes', () {
      expect(updateMinutesOf('1m'), 1);
      expect(updateMinutesOf('168h'), 168 * 60);
      expect(updateMinutesOf('60s'), 1);
      expect(updateMinutesOf('-'), isNull);
      expect(wzdxRefreshMinutes(1), 30);
      expect(wzdxRefreshMinutes(60), 60);
      expect(wzdxRefreshMinutes(null), 30);
    });
  });

  group('geometry', () {
    test('decodes an encoded polyline (the format of the 511 EncodedPolyline field)', () {
      final p = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
      expect(p.length, 3);
      expect(p[0].lat, closeTo(38.5, 1e-9));
      expect(p[0].lon, closeTo(-120.2, 1e-9));
      expect(p[1].lat, closeTo(40.7, 1e-9));
      expect(p[2].lon, closeTo(-126.453, 1e-9));
    });

    test('text that is not a polyline decodes to nothing, never an error', () {
      expect(decodePolyline(''), isEmpty);
      expect(decodePolyline(null), isEmpty);
      expect(decodePolyline('not a polyline \u0001'), isEmpty);
      expect(decodePolyline('~~~~~~~~~~~~~~~~~~~~'), isEmpty);
    });

    test('distance, point to line and coverage', () {
      final a = eastLine(boise, 11, 100); // 1 km
      expect(lengthM(a), closeTo(1000, 20));
      expect(pointToLineM(LL(boise.lat + 30 / 111320, boise.lon + 0.004), a), closeTo(30, 1.5));
      expect(coverage(a, a, bufferM: 50), 1.0);
      final shifted = [for (final p in a) LL(p.lat + 80 / 111320, p.lon)];
      expect(coverage(a, shifted, bufferM: 50), 0.0);
      final half = eastLine(boise, 6, 100);
      expect(coverage(a, half, bufferM: 50), closeTo(0.55, 0.12));
    });
  });

  group('de-duplication of a 511 event and a WZDx work zone', () {
    const rules = kDedupeRules;
    final line = eastLine(boise, 21, 100); // 2 km
    int day(int n) => 1795400000 + n * 86400;

    test('the thresholds are 50 m and half of each line, tested at both edges', () {
      expect(rules.bufferM, 50);
      expect(rules.minCoverage, 0.5);
      final e = ev('a', RoadEventSource.event511, line, start: day(0), end: day(5));
      for (final (off, same) in [(0.0, true), (30.0, true), (49.0, true), (51.0, false), (80.0, false)]) {
        final z = ev('z', RoadEventSource.workZone, [for (final p in line) LL(p.lat + off / 111320, p.lon)], start: day(1), end: day(4));
        expect(sameWorkZone(e, z), same, reason: 'offset $off m');
      }
    });

    test('a zone is the same only when each covers at least half of the other', () {
      final e = ev('a', RoadEventSource.event511, line, start: day(0), end: day(5));
      // the zone is the first 60 % of the closure: the zone is fully inside the closure and the closure is 60 % inside the zone
      final sixty = ev('z', RoadEventSource.workZone, line.sublist(0, 13), start: day(1), end: day(4));
      expect(sameWorkZone(e, sixty), isTrue);
      // a short zone (20 %) inside a long closure is another thing
      final twenty = ev('z', RoadEventSource.workZone, line.sublist(0, 5), start: day(1), end: day(4));
      expect(sameWorkZone(e, twenty), isFalse);
      // next to it along the road, only meeting at the end
      final next = ev('z', RoadEventSource.workZone, eastLine(line.last, 21, 100), start: day(1), end: day(4));
      expect(sameWorkZone(e, next), isFalse);
    });

    test('points: within 50 m of the other geometry', () {
      final e = ev('a', RoadEventSource.event511, [boise], start: day(0), end: day(5));
      expect(sameWorkZone(e, ev('z', RoadEventSource.workZone, [LL(boise.lat + 40 / 111320, boise.lon)], start: day(0))), isTrue);
      expect(sameWorkZone(e, ev('z', RoadEventSource.workZone, [LL(boise.lat + 60 / 111320, boise.lon)], start: day(0))), isFalse);
      final stretch = ev('z', RoadEventSource.workZone, line, start: day(0));
      final onIt = ev('a', RoadEventSource.event511, [LL(boise.lat + 20 / 111320, boise.lon + 0.01)], start: day(0));
      expect(sameWorkZone(onIt, stretch), isTrue);
    });

    test('date ranges must overlap; a missing end is open', () {
      final geo = ev('a', RoadEventSource.event511, line, start: day(0), end: day(5));
      ev2(int? s, int? e2) => ev('z', RoadEventSource.workZone, line, start: s, end: e2);
      expect(sameWorkZone(geo, ev2(day(5), day(9))), isTrue, reason: 'they touch on the last day');
      expect(sameWorkZone(geo, ev2(day(6), day(9))), isFalse);
      expect(sameWorkZone(geo, ev2(day(-9), day(-1))), isFalse);
      expect(sameWorkZone(geo, ev2(null, null)), isTrue, reason: 'no dates cannot rule a match out');
      expect(sameWorkZone(geo, ev2(day(6), null)), isFalse);
      final open = ev('a', RoadEventSource.event511, line, start: day(0));
      expect(sameWorkZone(open, ev2(day(50), day(60))), isTrue, reason: 'a 511 event with no end is still going');
      expect(dateRangesOverlap(1, 2, 2, 3), isTrue);
      expect(dateRangesOverlap(1, 2, 3, 4), isFalse);
    });

    test('a crash is never a work zone; a WZDx item is never the 511 one; two 511 events stay two', () {
      final crash = ev('c', RoadEventSource.event511, line, kind: RoadEventKind.crash, start: day(0), end: day(5));
      final zone = ev('z', RoadEventSource.workZone, line, start: day(0), end: day(5));
      expect(sameWorkZone(crash, zone), isFalse);
      expect(sameWorkZone(zone, zone), isFalse);
      final other = ev('o', RoadEventSource.event511, line, start: day(0), end: day(5));
      expect(dedupeWorkZones([other, other]).length, 2);
    });

    test('the 511 version is kept and the order is kept', () {
      final e = ev('511', RoadEventSource.event511, line, kind: RoadEventKind.closure, start: day(0), end: day(5));
      final dup = ev('wz-same', RoadEventSource.workZone, line, start: day(1), end: day(4));
      final far = ev('wz-far', RoadEventSource.workZone, [for (final p in line) LL(p.lat + 0.05, p.lon)], start: day(1), end: day(4));
      final crash = ev('crash', RoadEventSource.event511, [boise], kind: RoadEventKind.crash, start: day(0));
      final out = dedupeWorkZones([dup, far, e, crash]);
      expect(out.map((x) => x.id), ['wz-far', '511', 'crash']);
      expect(dedupeWorkZones([far, dup]).length, 2, reason: 'no 511 event, nothing to drop');
    });
  });
}
