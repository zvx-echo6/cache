// One pop-up per alert (alerts part 2): copies of the same alert from NWS and FEMA IPAWS, and at several watched places, pop up
// once; an update or a later copy of an alert told about does not pop up again. The NWS and IPAWS items are the core's view
// (cs_live_get) of the same real flash flood warning of 2026-10-29 (cache_live tests/fixtures/ipaws: nws_ffw.json and
// cap_nws_ffw.xml).
import 'dart:convert';
import 'dart:io';

import 'package:cache/weather/alert_area.dart';
import 'package:cache/weather/alert_watch.dart';
import 'package:cache/weather/catalogue.dart';
import 'package:cache/weather/connector.dart';
import 'package:cache/weather/live_view.dart';
import 'package:cache/weather/places.dart';
import 'package:cache/weather/weather_state.dart';
import 'package:flutter_test/flutter_test.dart';

Connector src(String id, String category) => Connector.parse('{"id": "$id"}',
    entry: CatalogueEntry(id: id, title: id, description: '', category: category, provider: '', coverage: 'US', needsKey: false, keyAlias: null,
        defaultOn: false, path: '', attribution: '', license: '', docs: null, sha256: null));

WatchPlace place(String id, String name) => WatchPlace(id: id, kind: PlaceKind.saved, name: name, subtitle: '', lat: 33.36, lon: -105.68, key: id);

const ffwPolygon = {
  'type': 'Polygon',
  'coordinates': [
    [[-105.71, 33.42], [-105.66, 33.42], [-105.65, 33.43], [-105.63, 33.44], [-105.61, 33.4], [-105.62, 33.38], [-105.64, 33.39], [-105.64, 33.34],
     [-105.63, 33.33], [-105.56, 33.36], [-105.53, 33.38], [-105.43, 33.43], [-105.43, 33.41], [-105.55, 33.33], [-105.59, 33.31], [-105.73, 33.31],
     [-105.73, 33.39], [-105.78, 33.39], [-105.78, 33.41], [-105.71, 33.42]],
  ],
};

/// The NWS copy, as nws-alerts-point maps it.
LiveItem nws(String placeKey, {String id = 'urn:oid:2.49.0.1.840.0.e6e8f35546b1bcf3ea5ca9fb6c6d9c0ebfe11d2a.001.1', String expires = '2026-10-29 16:30', Object? area = ffwPolygon}) =>
    LiveItem.fromJson({
      'address': 'live:nws-alerts-point/$placeKey/$id',
      'label': 'Flash Flood Warning',
      'time': '2026-10-29T13:36:00-06:00',
      'fields': {'Severity': 'severe', 'Urgency': 'immediate', 'Area': 'Lincoln, NM', 'Distance': 'inside the area', 'Expires': expires},
      'area': area,
    });

/// The IPAWS copy, as ipaws-alerts-near maps it (its label is the CAP headline, its event a field).
LiveItem ipaws(String placeKey) => LiveItem.fromJson({
  'address': 'live:ipaws-alerts-near/$placeKey/urn:oid:2.49.0.1.840.0.e6e8f35546b1bcf3ea5ca9fb6c6d9c0ebfe11d2a.001.1.IPAWS',
  'label': 'Flash Flood Warning issued October 29 at 1:36PM MDT until October 29 at 4:30PM MDT by NWS Albuquerque NM',
  'time': '2026-10-29T13:36:00-06:00',
  'fields': {'Event': 'Flash Flood Warning', 'Severity': 'severe', 'Issued by': 'NWS Albuquerque NM', 'Area': 'Lincoln, NM', 'Expires': '2026-10-29 16:30'},
  'area': {'type': 'GeometryCollection', 'geometries': [ffwPolygon]},
});

void main() {
  final nwsSrc = src('nws-alerts-point', 'alerts'), ipawsSrc = src('ipaws-alerts-near', 'alerts'), fireSrc = src('wfigs-incidents-near', 'fire');
  SourceView view(WatchPlace p, Connector c, List<LiveItem> items) => SourceView(source: c, place: p, items: items);

  group('area match', () {
    test('areas that overlap, touch, contain a point, or miss', () {
      Map<String, Object> box(double w, double s, double e, double n) => boxPolygon([w, s, e, n]);
      expect(areasMeet(box(-114, 42, -113, 43), box(-113.5, 42.5, -112.5, 43.5)), isTrue);
      expect(areasMeet(box(-114, 42, -113, 43), box(-113.8, 42.2, -113.6, 42.4)), isTrue, reason: 'one inside the other');
      expect(areasMeet(box(-113.8, 42.2, -113.6, 42.4), box(-114, 42, -113, 43)), isTrue);
      expect(areasMeet(box(-114, 42, -113, 43), box(-114, 43, -113, 44)), isTrue, reason: 'a shared edge');
      expect(areasMeet(box(-114, 42, -113, 43), box(-114, 44, -113, 45)), isFalse);
      expect(areasMeet(ffwPolygon, {'type': 'Point', 'coordinates': [-105.68, 33.36]}), isTrue);
      expect(areasMeet(ffwPolygon, {'type': 'Point', 'coordinates': [-106.5, 35.1]}), isFalse);
      expect(areasMeet({'type': 'GeometryCollection', 'geometries': [ffwPolygon]}, boxesArea([[-106, 33, -105.7, 33.5]])), isTrue);
      expect(areasMeet(null, ffwPolygon), isFalse);
      expect(boxOf(ffwPolygon), [-105.78, 33.31, -105.43, 33.44]);
    });

    test('a region is watched by its whole area: the boxes of its maps go to the core with its middle', () {
      final r = WatchRegion(name: 'North', lat: 47, lon: -116, boxes: const [[-117, 45.5, -115, 48.9], [-117, 45.5, -115, 48.9], [-116, 44, -115, 45.5]]);
      expect(r.area!['type'], 'MultiPolygon');
      final p = WatchPlace(id: 'region:North', kind: PlaceKind.region, name: 'North', subtitle: '', lat: r.lat, lon: r.lon, key: 'region-north', area: r.area);
      final req = WeatherState.placeRequest(p);
      expect(req['area'], r.area);
      expect(req['lat'], 47);
      // a point carries no area
      expect(WeatherState.placeRequest(place('place:home', 'Home')).containsKey('area'), isFalse);
    });
  });

  group('one pop-up per alert', () {
    test('the NWS and IPAWS copies of one warning pop up once, as the first source shows it', () {
      final home = place('place:home', 'Home');
      final out = pickNewAlerts({home: [view(home, nwsSrc, [nws('home')]), view(home, ipawsSrc, [ipaws('home')])]}, const {});
      expect(out, hasLength(1));
      expect(out.single.title, 'Flash Flood Warning near Home');
      expect(out.single.serious, isTrue);
      expect(out.single.allAddresses, hasLength(2));
      expect(capId(ipaws('home')), capId(nws('home')));
    });

    test('the same alert near two watched places is one pop-up naming both', () {
      final home = place('place:home', 'Home'), cabin = place('place:cabin', 'Cabin');
      final out = pickNewAlerts({
        home: [view(home, nwsSrc, [nws('home')])],
        cabin: [view(cabin, nwsSrc, [nws('cabin')]), view(cabin, ipawsSrc, [ipaws('cabin')])],
      }, const {});
      expect(out.map((a) => a.title), ['Flash Flood Warning near Home and Cabin']);
      expect(placeWords(['Home', 'Cabin', 'Shop']), 'Home, Cabin and Shop');
    });

    test('without an identifier in common: same event, same ground, same time is one; otherwise two', () {
      final home = place('place:home', 'Home');
      // another identifier (a relay, an update): same event over the same polygon at the same time
      final other = nws('home', id: 'urn:oid:other.001.1');
      final joined = pickNewAlerts({home: [view(home, nwsSrc, [nws('home')]), view(home, ipawsSrc, [LiveItem.fromJson({...{
        'address': 'live:ipaws-alerts-near/home/x-1', 'label': 'Flash flood warning for the burn scar', 'time': '2026-10-29T13:40:00-06:00',
        'fields': {'Event': 'Flash Flood Warning', 'Expires': '2026-10-29 16:30'}, 'area': ffwPolygon}})])]}, const {});
      expect(joined, hasLength(1));
      // the same source never lists one alert twice: two identifiers of one source are two alerts
      expect(pickNewAlerts({home: [view(home, nwsSrc, [nws('home'), other])]}, const {}), hasLength(2));
      // another event at the same time and place: two
      final heat = LiveItem.fromJson({'address': 'live:ipaws-alerts-near/home/h', 'label': 'Heat', 'time': '2026-10-29T13:36:00-06:00',
        'fields': {'Event': 'Excessive Heat Warning'}, 'area': ffwPolygon});
      expect(pickNewAlerts({home: [view(home, nwsSrc, [nws('home')]), view(home, ipawsSrc, [heat])]}, const {}), hasLength(2));
      // the same event far away: two
      final far = LiveItem.fromJson({'address': 'live:ipaws-alerts-near/home/f', 'label': 'FFW', 'time': '2026-10-29T13:36:00-06:00',
        'fields': {'Event': 'Flash Flood Warning'}, 'area': boxPolygon([-110, 40, -109, 41])});
      expect(pickNewAlerts({home: [view(home, nwsSrc, [nws('home')]), view(home, ipawsSrc, [far])]}, const {}), hasLength(2));
      // the same event over the same ground the next day: two
      final later = LiveItem.fromJson({'address': 'live:ipaws-alerts-near/home/l', 'label': 'FFW', 'time': '2026-10-30T13:36:00-06:00',
        'fields': {'Event': 'Flash Flood Warning', 'Expires': '2026-10-30 16:30'}, 'area': ffwPolygon});
      expect(pickNewAlerts({home: [view(home, nwsSrc, [nws('home')]), view(home, ipawsSrc, [later])]}, const {}), hasLength(2));
      // no areas: the same event at the same watched place at the same time is one; at two places it is two
      final cabin = place('place:cabin', 'Cabin');
      final zoneA = nws('home', id: 'zone-a', area: null), zoneB = LiveItem.fromJson({'address': 'live:ipaws-alerts-near/home/zone-b',
        'label': 'x', 'time': '2026-10-29T14:00:00-06:00', 'fields': {'Event': 'Flash Flood Warning'}});
      expect(pickNewAlerts({home: [view(home, nwsSrc, [zoneA]), view(home, ipawsSrc, [zoneB])]}, const {}), hasLength(1));
      expect(pickNewAlerts({home: [view(home, nwsSrc, [zoneA])], cabin: [view(cabin, ipawsSrc, [zoneB])]}, const {}), hasLength(2));
    });

    test('a copy or an update of an alert told about does not pop up again; old told lists still count', () async {
      final dir = Directory.systemTemp.createTempSync('cache-told-');
      final store = ToldStore(File('${dir.path}/alerts_told.json'));
      // a told list from before (addresses only)
      File('${dir.path}/alerts_told.json').writeAsStringSync(jsonEncode(['live:nws-alerts-point/home/old-1']));
      final home = place('place:home', 'Home');
      final first = pickNewAlerts({home: [view(home, nwsSrc, [nws('home')])]}, await store.read(), toldAlerts: await store.readAlerts());
      expect(first, hasLength(1));
      await store.add([for (final a in first) ...a.allAddresses], alerts: [for (final a in first) ...a.told]);
      // the IPAWS copy arrives later (the next check): told already
      final told = await store.read(), alerts = await store.readAlerts();
      expect(told, containsAll(['live:nws-alerts-point/home/old-1', nws('home').address]));
      expect(alerts.single.id, 'urn:oid:2.49.0.1.840.0.e6e8f35546b1bcf3ea5ca9fb6c6d9c0ebfe11d2a.001.1');
      expect(pickNewAlerts({home: [view(home, ipawsSrc, [ipaws('home')])]}, told, toldAlerts: alerts), isEmpty);
      // an NWS update (a new identifier, extended to 18:00) over the same ground: told already
      final update = nws('home', id: 'urn:oid:2.49.0.1.840.0.update.001.1', expires: '2026-10-29 18:00');
      expect(pickNewAlerts({home: [view(home, nwsSrc, [update])]}, told, toldAlerts: alerts), isEmpty);
      // an alert from before, by its address
      final old = LiveItem.fromJson({'address': 'live:nws-alerts-point/home/old-1', 'label': 'Wind Advisory', 'fields': {}});
      expect(pickNewAlerts({home: [view(home, nwsSrc, [old])]}, told, toldAlerts: alerts), isEmpty);
    });

    test('fires are joined only with the same fire of the same source', () {
      final home = place('place:home', 'Home'), cabin = place('place:cabin', 'Cabin');
      LiveItem fire(String p, String k) => LiveItem.fromJson({'address': 'live:wfigs-incidents-near/$p/$k', 'label': 'East Fork fire', 'fields': {'Distance': '4 mi N'}});
      final out = pickNewAlerts({home: [view(home, fireSrc, [fire('home', 'f1')])], cabin: [view(cabin, fireSrc, [fire('cabin', 'f1'), fire('cabin', 'f2')])]}, const {});
      expect(out.map((a) => a.title), ['East Fork fire near Home and Cabin', 'East Fork fire near Cabin']);
      expect(out.first.serious, isTrue);
    });

    test('alert spans read Expires in the place\'s local time', () {
      final s = alertSpan(nws('home'))!;
      expect(s.from, DateTime.utc(2026, 10, 29, 19, 36));
      expect(s.to, DateTime.utc(2026, 10, 29, 22, 30));
    });
  });
}
