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

  // 1.1 audit, finding 3: an alert told about was "the same" as any later one with the same event name, at an overlapping time,
  // whose box met its box, so a second warning of the same kind never popped up. Where the source gives the message type,
  // references and VTEC (the built-in alerts source does), those decide; elsewhere the areas themselves are compared.
  group('an update of an alert, or another alert', () {
    const sender = 'w-nws.webmaster@noaa.gov';
    const a1 = 'urn:oid:2.49.0.1.840.0.aaaa.001.1', a2 = 'urn:oid:2.49.0.1.840.0.bbbb.001.1', a3 = 'urn:oid:2.49.0.1.840.0.cccc.001.1';
    String vtec(String action, String number) => '/O.$action.KABQ.FF.W.$number.261029T1936Z-261029T2230Z/';
    // ground east of the recorded warning's polygon, touching it along its east edge
    const east = {
      'type': 'Polygon',
      'coordinates': [
        [[-105.43, 33.36], [-105.30, 33.36], [-105.30, 33.45], [-105.43, 33.45], [-105.43, 33.36]],
      ],
    };

    /// A warning as the built-in alerts source maps it, with what it gives the app alone (message type, references, VTEC).
    LiveItem msg(String placeKey, String id, {String type = 'Alert', List<String> refs = const [], String? line, String severity = 'severe', String expires = '2026-10-29 16:30', Object? area = ffwPolygon, bool identity = true}) =>
        LiveItem.fromJson({
          'address': 'live:nws-alerts-point/$placeKey/$id',
          'label': 'Flash Flood Warning',
          'time': '2026-10-29T13:36:00-06:00',
          'fields': {'Severity': severity, 'Expires': expires},
          'area': area,
          if (identity)
            'app': {
              'message_type': type,
              'references': [for (final r in refs) {'identifier': r, 'sender': sender, 'sent': '2026-10-29T13:36:00-06:00'}],
              'vtec': ?(line == null ? null : [line]),
            },
        });

    final ridge = place('place:ridge', 'Ridge Farm'), mill = place('place:mill', 'Mill Camp');

    /// One alert check against [list], the told list as its file holds it: what pops up, which is then remembered.
    List<NewAlert> check(Map<WatchPlace, List<LiveItem>> seen, List<Object?> list) {
      final kept = jsonDecode(jsonEncode(list)) as List;
      final out = pickNewAlerts(
        {for (final e in seen.entries) e.key: [view(e.key, nwsSrc, e.value)]},
        {for (final x in kept) if (x is String) x},
        toldAlerts: [for (final x in kept) ?ToldAlert.fromJson(x)],
      );
      list.addAll([for (final a in out) ...a.allAddresses, for (final a in out) ...a.marks, for (final a in out) for (final t in a.told) t.toJson()]);
      return out;
    }

    /// A told list in which the first warning (event number 0239) was told at Ridge Farm.
    List<Object?> toldAtRidge() {
      final list = <Object?>[];
      expect(check({ridge: [msg('ridge', a1, line: vtec('NEW', '0239'))]}, list).single.title, 'Flash Flood Warning near Ridge Farm');
      return list;
    }

    test('an update of a told alert does not pop up: by its references, or by its NWS event number', () {
      final byRefs = toldAtRidge();
      expect(check({ridge: [msg('ridge', a2, type: 'Update', refs: [a1])]}, byRefs), isEmpty);
      final byEvent = toldAtRidge();
      expect(check({ridge: [msg('ridge', a2, type: 'Update', line: vtec('CON', '0239'))]}, byEvent), isEmpty);
      // the older message arriving after its update (another source is behind): still the same alert
      final late = <Object?>[];
      check({ridge: [msg('ridge', a2, type: 'Update', refs: [a1], line: vtec('CON', '0239'))]}, late);
      expect(check({ridge: [msg('ridge', a1, line: vtec('NEW', '0239'))]}, late), isEmpty);
      // two updates of the same first message
      expect(check({ridge: [msg('ridge', a3, type: 'Update', refs: [a1])]}, late), isEmpty);
    });

    test('the recorded IPAWS update (Idaho, 2026-07-15) is its original again, by the reference the CAP document carries', () {
      final cap = File('../packages/cache_search/native/cache_live/tests/fixtures/ipaws/cap_idaho_cem.xml').readAsStringSync();
      String tag(String name) => RegExp('<$name>([^<]*)</$name>').firstMatch(cap)!.group(1)!;
      expect(tag('msgType'), 'Update');
      LiveItem civil(String id, String type, String? references, String sent) => LiveItem.fromJson({
        'address': 'live:ipaws-alerts-near/ridge/$id',
        'label': 'Civil Emergency Message',
        'time': sent,
        'fields': {'Event': tag('event'), 'Severity': 'extreme', 'Expires': '2026-07-16 02:54'},
        'app': {'message_type': type, 'references': ?references},
      });
      final update = civil(tag('identifier'), tag('msgType'), tag('references'), tag('sent'));
      final original = alertRefs(update).single;
      expect(original, 'AS-ID-f99c29ec-6485-4946-bad1-f4c679204f91');
      final list = <Object?>[];
      List<NewAlert> seen(LiveItem i) {
        final kept = jsonDecode(jsonEncode(list)) as List;
        final out = pickNewAlerts({ridge: [view(ridge, ipawsSrc, [i])]}, {for (final x in kept) if (x is String) x}, toldAlerts: [for (final x in kept) ?ToldAlert.fromJson(x)]);
        list.addAll([for (final a in out) ...a.allAddresses, for (final a in out) for (final t in a.told) t.toJson()]);
        return out;
      }

      expect(seen(civil(original, 'Alert', null, '2026-07-15T22:18:49-06:00')), hasLength(1));
      expect(seen(update), isEmpty, reason: 'the update names the message told about');
      // another civil emergency message with no reference to it is another alert
      expect(seen(civil('AS-ID-00000000-made-up', 'Alert', null, '2026-07-15T23:10:00-06:00')), hasLength(1));
    });

    test('a second warning of the same kind with a new event number pops up, at the same place and at a second one', () {
      final list = toldAtRidge();
      // the same event name, an overlapping time, ground that touches the first one's: it reaches Mill Camp only
      final second = check({mill: [msg('mill', a2, line: vtec('NEW', '0240'), area: east)]}, list);
      expect(second.single.title, 'Flash Flood Warning near Mill Camp');
      expect(check({mill: [msg('mill', a2, line: vtec('NEW', '0240'), area: east)]}, list), isEmpty, reason: 'once');
      // and a separate warning for the same place while the first is in force
      final again = toldAtRidge();
      expect(check({ridge: [msg('ridge', a2, line: vtec('NEW', '0240'))]}, again).single.title, 'Flash Flood Warning near Ridge Farm');
      // with no VTEC at all (a statement): a new identifier that references nothing told is another alert
      final plain = <Object?>[];
      check({ridge: [msg('ridge', a1)]}, plain);
      expect(check({ridge: [msg('ridge', a2)]}, plain), hasLength(1));
    });

    test('an update that raises the severity pops up again; a later end or the same severity does not', () {
      final list = toldAtRidge();
      expect(check({ridge: [msg('ridge', a2, type: 'Update', refs: [a1], expires: '2026-10-29 18:00')]}, list), isEmpty, reason: 'only the end moved');
      final graver = check({ridge: [msg('ridge', a3, type: 'Update', refs: [a1, a2], severity: 'extreme')]}, list);
      expect(graver.single.title, 'Flash Flood Warning near Ridge Farm');
      expect(graver.single.extreme, isTrue);
      expect(check({ridge: [msg('ridge', a3, type: 'Update', refs: [a1, a2], severity: 'extreme')]}, list), isEmpty, reason: 'told as extreme now');
      expect(check({ridge: [msg('ridge', 'urn:oid:later', type: 'Update', refs: [a3], severity: 'severe')]}, list), isEmpty, reason: 'less grave is not news');
    });

    test('an update whose area now reaches another watched place pops up for that place only', () {
      final list = toldAtRidge();
      final wider = {
        'type': 'GeometryCollection',
        'geometries': [ffwPolygon, east],
      };
      final out = check({
        ridge: [msg('ridge', a2, type: 'Update', refs: [a1], line: vtec('EXA', '0239'), area: wider)],
        mill: [msg('mill', a2, type: 'Update', refs: [a1], line: vtec('EXA', '0239'), area: wider)],
      }, list);
      expect(out.single.title, 'Flash Flood Warning near Mill Camp');
      expect([for (final p in out.single.places) p.name], ['Mill Camp']);
      expect(out.single.payload, contains('place:mill'));
      expect(check({
        ridge: [msg('ridge', a2, type: 'Update', refs: [a1], area: wider)],
        mill: [msg('mill', a2, type: 'Update', refs: [a1], area: wider)],
      }, list), isEmpty, reason: 'both places know now');
    });

    test('an alert for zones, with no polygon: its updates are known by reference and event number, and another one pops up', () {
      final list = <Object?>[];
      expect(check({ridge: [msg('ridge', a1, line: vtec('NEW', '0239'), area: null)]}, list), hasLength(1));
      expect(check({ridge: [msg('ridge', a2, type: 'Update', refs: [a1], area: null)]}, list), isEmpty);
      expect(check({ridge: [msg('ridge', a3, type: 'Update', line: vtec('EXT', '0239'), area: null)]}, list), isEmpty);
      expect(check({ridge: [msg('ridge', 'urn:oid:other', line: vtec('NEW', '0240'), area: null)]}, list), hasLength(1));
      expect(check({mill: [msg('mill', a3, type: 'Update', line: vtec('EXT', '0239'), area: null)]}, list).single.title, 'Flash Flood Warning near Mill Camp');
    });

    test('a told list from before the update still counts: nothing in it pops up again', () {
      // what the list held: addresses, and alerts with the identifier, event, box, times and places only
      final before = <Object?>[
        'live:nws-alerts-point/ridge/$a1',
        {'id': a1, 'event': 'flash flood warning', 'box': boxOf(ffwPolygon), 'from': '2026-10-29T19:36:00.000Z', 'to': '2026-10-29T22:30:00.000Z', 'places': ['place:ridge']},
      ];
      expect(ToldAlert.fromJson(before[1])!.messageType, isNull);
      expect(check({ridge: [msg('ridge', a1, line: vtec('NEW', '0239'))]}, [...before]), isEmpty, reason: 'the alert itself');
      expect(check({ridge: [msg('ridge', a2, type: 'Update', refs: [a1], line: vtec('CON', '0239'), expires: '2026-10-29 18:00')]}, [...before]), isEmpty, reason: 'its update');
      expect(check({ridge: [msg('ridge', a2, type: 'Update', refs: [a1], severity: 'extreme')]}, [...before]), isEmpty,
          reason: 'the old list has no severity to compare: not taken as graver');
      // a source that gives no message type, against the old record: the comparison there was (same event, time and ground)
      expect(check({ridge: [msg('ridge', a2, identity: false)]}, [...before]), isEmpty);
    });

    test('where a source gives neither references nor VTEC, the areas themselves are compared, not their boxes', () {
      // two triangles in one square: the boxes are the same box, the areas only share nothing
      const lower = {'type': 'Polygon', 'coordinates': [[[0.0, 0.0], [4.0, 0.0], [0.0, 4.0], [0.0, 0.0]]]};
      const upper = {'type': 'Polygon', 'coordinates': [[[4.0, 1.0], [4.0, 4.0], [1.0, 4.0], [4.0, 1.0]]]};
      expect(areasMeet(lower, upper), isFalse);
      expect(areasMeet(boxPolygon(boxOf(lower)!), boxPolygon(boxOf(upper)!)), isTrue);
      final list = <Object?>[];
      expect(check({ridge: [msg('ridge', a1, identity: false, area: lower)]}, list), hasLength(1));
      expect(check({ridge: [msg('ridge', a2, identity: false, area: upper)]}, list), hasLength(1), reason: 'other ground: another alert');
      expect(check({ridge: [msg('ridge', a3, identity: false, area: lower)]}, list), isEmpty, reason: 'the same ground: an update');
      // and such an update still pops up at a place the alert was not told for
      expect(check({mill: [msg('mill', a3, identity: false, area: lower)]}, list).single.title, 'Flash Flood Warning near Mill Camp');
    });

    test('what the app reads from a message: references in both shapes, VTEC event numbers, a cancel', () {
      final nwsShape = msg('ridge', a2, type: 'Update', refs: [a1, '$a3.IPAWS'], line: vtec('CON', '0239'));
      expect(alertRefs(nwsShape), [a1, a3]);
      expect(alertVtec(nwsShape), {'KABQ.FF.W.0239'});
      // a CAP document: one text of sender,identifier,sent groups; VTEC among its parameters (the recorded NWS warning's)
      final capShape = LiveItem.fromJson({
        'address': 'live:ipaws-alerts-near/ridge/x',
        'label': 'x',
        'app': {
          'message_type': 'Update',
          'references': '$sender,$a1,2026-10-29T13:36:00-06:00 $sender,$a2.IPAWS,2026-10-29T14:00:00-06:00',
          'parameters': [
            {'valueName': 'AWIPSidentifier', 'value': 'FFWABQ'},
            {'valueName': 'VTEC', 'value': '/O.NEW.KABQ.FF.W.0239.261029T1936Z-261029T2230Z/'},
          ],
        },
      });
      expect(alertRefs(capShape), [a1, a2]);
      expect(alertVtec(capShape), {'KABQ.FF.W.0239'});
      // a watch upgraded to a warning: the line for the watch names the event that ended, not this message's
      final upgrade = LiveItem.fromJson({'address': 'a/b/c', 'label': 'x', 'app': {'message_type': 'Alert', 'vtec': ['/O.UPG.KABQ.FF.A.0012.000000T0000Z-261029T2230Z/', '/O.NEW.KABQ.FF.W.0240.261029T1936Z-261029T2230Z/']}});
      expect(alertVtec(upgrade), {'KABQ.FF.W.0240'});
      expect(alertVtec(msg('ridge', a1, identity: false)), isEmpty);
      // a cancel: the message and the alert it takes back are not listed and so never pop up
      final cancel = msg('ridge', a2, type: 'Cancel', refs: [a1], line: vtec('CAN', '0239'));
      final other = msg('ridge', a3, line: vtec('NEW', '0240'));
      expect(isCancel(cancel), isTrue);
      expect([for (final i in withoutCancelled([msg('ridge', a1, line: vtec('NEW', '0239')), cancel, other])) capId(i)], [a3]);
      expect(withoutCancelled([other]), [other]);
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

    // 1.1 audit: two writers (the app and a background run) shared one temporary file, and a list that could not be read was
    // taken as an empty one.
    test('the told list: two writers at once leave a whole list; a damaged one falls back to its copy, then to what was read', () async {
      final dir = Directory.systemTemp.createTempSync('cache-told-');
      final file = File('${dir.path}/alerts_told.json'), copy = File('${dir.path}/alerts_told.json.bak');
      final none = await ToldStore(file).load();
      expect(none.known, isTrue, reason: 'no file: nothing was told, and that is known');
      expect(none.addresses, isEmpty);
      await Future.wait([ToldStore(file).add(['live:a/home/1']), ToldStore(file).add(['live:a/home/2'])]);
      expect(jsonDecode(file.readAsStringSync()), isList);
      expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty, reason: 'each write finished its own file');
      await ToldStore(file).add(['live:a/home/3']);
      final whole = await ToldStore(file).load();
      expect(whole.addresses, contains('live:a/home/3'));
      // the list is damaged: the copy beside it
      file.writeAsStringSync('["live:a/ho');
      final reader = ToldStore(file);
      final fromCopy = await reader.load();
      expect(fromCopy.known, isTrue);
      expect(fromCopy.addresses, whole.addresses);
      // the copy too: a store that read it before still knows; a new one does not, and says so
      copy.writeAsStringSync('{}');
      expect((await reader.load()).addresses, whole.addresses);
      final lost = await ToldStore(file).load();
      expect(lost.known, isFalse);
      expect(lost.addresses, isEmpty);
      dir.deleteSync(recursive: true);
    });

    test('an item at "Where I am" is known without the position in its address; at a saved place by its address', () {
      expect(hereMark('live:wfigs-incidents-near/at:42.54,-113.79/EF1'), 'live:wfigs-incidents-near/at:/EF1');
      expect(hereMark('live:wfigs-incidents-near/at:42.55,-113.79/EF1'), hereMark('live:wfigs-incidents-near/at:42.54,-113.79/EF1'));
      expect(hereMark('live:own-creek/at:42.54,-113.79~1a2b3c4d/a/b'), 'live:own-creek/at:~1a2b3c4d/a/b');
      expect(hereMark('live:wfigs-incidents-near/home/EF1'), isNull);
      expect(hereMark(seriousMark('live:wfigs-incidents-near/at:/EF1')), isNull);
      // a saved place: a fire told near Home is still new when it comes near Cabin later
      final home = place('place:home', 'Home'), cabin = place('place:cabin', 'Cabin');
      LiveItem fire(String p) => LiveItem.fromJson({'address': 'live:wfigs-incidents-near/$p/f1', 'label': 'East Fork fire', 'fields': {'Distance': '40 mi N'}});
      final told = {fire('home').address};
      expect(pickNewAlerts({home: [view(home, fireSrc, [fire('home')])]}, told), isEmpty);
      expect(pickNewAlerts({cabin: [view(cabin, fireSrc, [fire('cabin')])]}, told), hasLength(1));
      // "Where I am": the same fire at another position is told already, until it is serious and was not told as serious
      const here = WatchPlace(id: 'here', kind: PlaceKind.here, name: 'Where I am', subtitle: '', lat: 42.55, lon: -113.79, key: 'at:42.55,-113.79');
      LiveItem at(String key, String miles) => LiveItem.fromJson({'address': 'live:wfigs-incidents-near/$key/f1', 'label': 'East Fork fire', 'fields': {'Distance': miles}});
      final before = {at('at:42.54,-113.79', '40 mi N').address};
      expect(pickNewAlerts({here: [view(here, fireSrc, [at('at:42.55,-113.79', '39 mi N')])]}, before), isEmpty);
      final close = pickNewAlerts({here: [view(here, fireSrc, [at('at:42.55,-113.79', '4 mi N')])]}, before);
      expect(close.single.marks, ['serious:live:wfigs-incidents-near/at:/f1']);
      expect(pickNewAlerts({here: [view(here, fireSrc, [at('at:42.56,-113.79', '3 mi N')])]}, {...before, ...close.single.allAddresses, ...close.single.marks}), isEmpty);
    });

    test('every fire source is listed; a fire two of them name is listed once; the sources take turns', () {
      final home = place('place:home', 'Home');
      final perimeterSrc = src('wfigs-perimeters-near', 'fire'), satelliteSrc = src('firms-viirs-near', 'fire');
      LiveItem item(String source, String key, String label) => LiveItem.fromJson({'address': 'live:$source/home/$key', 'label': label, 'fields': {}});
      final detections = view(home, satelliteSrc, [for (var k = 1; k <= 5; k++) item('firms-viirs-near', 'd$k', 'Satellite fire detection')]);
      final incidents = view(home, fireSrc, [item('wfigs-incidents-near', '1', 'East Fork fire'), item('wfigs-incidents-near', '2', 'Forleen fire')]);
      final perimeters = view(home, perimeterSrc, [item('wfigs-perimeters-near', '1', 'East Fork Fire  Perimeter'), item('wfigs-perimeters-near', '7', 'Bear Gulch fire perimeter')]);
      expect(fireName(perimeters.items.first), 'east fork fire');
      expect(ownFireNames(detections), isEmpty, reason: 'a label every item has names no fire');
      expect([for (final (i, _) in firesOnce([detections, incidents, perimeters])) i.label], [
        'Satellite fire detection', 'East Fork fire', 'Bear Gulch fire perimeter',
        'Satellite fire detection', 'Forleen fire',
        'Satellite fire detection', 'Satellite fire detection', 'Satellite fire detection',
      ]);
      // as pop-ups: each detection, each named fire once (the two feeds' East Fork joined), and the same key in two feeds is not the same fire
      final out = pickNewAlerts({home: [detections, incidents, perimeters]}, const {});
      expect(out.where((a) => a.item.label == 'Satellite fire detection'), hasLength(5));
      expect([for (final a in out) if (a.item.label != 'Satellite fire detection') a.item.label], ['East Fork fire', 'Forleen fire', 'Bear Gulch fire perimeter']);
      expect(out.firstWhere((a) => a.item.label == 'East Fork fire').allAddresses, ['live:wfigs-incidents-near/home/1', 'live:wfigs-perimeters-near/home/1']);
      final sameKey = pickNewAlerts({home: [view(home, fireSrc, [item('wfigs-incidents-near', '1', 'East Fork fire')]), view(home, perimeterSrc, [item('wfigs-perimeters-near', '1', 'Bear Gulch fire perimeter')])]}, const {});
      expect(sameKey, hasLength(2));
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
