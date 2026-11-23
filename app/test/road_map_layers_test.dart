import 'dart:convert';
import 'dart:typed_data';

import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/style/style_generator.dart';
import 'package:cache/roads/road_chips.dart';
import 'package:cache/roads/road_event.dart';
import 'package:cache/roads/road_event_card.dart';
import 'package:cache/roads/road_events_state.dart';
import 'package:cache/roads/road_geo.dart';
import 'package:cache/roads/road_map_layers.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/live_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const String kLine = 'kabiGpg}dU?etBXqYVaG|@cL`@gD';
const String kDetour = 'kabiG||_eU^ijBfKh@t\\FJi@E}L?mtCRgz@MY{IO';

RoadEvent ev(String id, RoadEventKind kind, {List<LL> line = const [], Heading? heading, bool full = false, bool stale = false, List<LL> detour = const [], String? age, Map<String, String> fields = const {}, List<String> steps = const []}) => RoadEvent(
  id: id,
  source: RoadEventSource.event511,
  sourceId: 'idaho511-events',
  kind: kind,
  road: 'I-84',
  line: line,
  point: line.isEmpty ? const LL(43.6, -116.28) : line.first,
  heading: heading,
  fullClosure: full,
  detour: detour,
  stale: stale,
  age: age,
  fields: fields,
  detourSteps: steps,
  credit: 'Road events: Idaho 511',
);

void main() {
  group('the two new palette roles', () {
    const expected = {
      CacheThemeId.light: (0xA3127A, 0xC28100),
      CacheThemeId.dark: (0xFF6FD0, 0xFFC933),
      CacheThemeId.parchment: (0x7C1A6E, 0x9A6A00),
      CacheThemeId.tactical: (0xFFB4A6, 0xC45A48),
    };

    test('eventClosure and eventWork are in every theme, with the design\'s colours', () {
      expect(MapPalette.roleNames, containsAll(['eventClosure', 'eventWork']));
      for (final id in CacheThemeId.values) {
        final p = mapPaletteFor(id);
        final (closure, work) = expected[id]!;
        expect(p.css('eventClosure'), '#${closure.toRadixString(16)}', reason: id.name);
        expect(p.css('eventWork'), '#${work.toRadixString(16)}', reason: id.name);
      }
    });

    test('a theme missing the roles is refused', () {
      expect(() => MapPalette(CacheThemeId.light, {'land': const Color(0xFF000000)}), throwsArgumentError);
    });

    test('a closure is not the colour of the person\'s own pin', () {
      for (final id in CacheThemeId.values) {
        expect(mapPaletteFor(id)['eventClosure'], isNot(mapPaletteFor(id)['pin']));
      }
    });
  });

  group('the side an event line is drawn on', () {
    final east = [const LL(43.6, -116.30), const LL(43.6, -116.28)];

    test('the right of the direction of travel: the geometry\'s right when it runs the same way, its left when it runs the other', () {
      expect(sideOf(east, Heading.east), 1);
      expect(sideOf(east, Heading.west), -1);
      expect(sideOf(east.reversed.toList(), Heading.west), 1);
      expect(sideOf([const LL(43.6, -116.3), const LL(43.7, -116.3)], Heading.north), 1);
      expect(sideOf([const LL(43.6, -116.3), const LL(43.7, -116.3)], Heading.south), -1);
    });

    test('with no direction, or no line, the right of the geometry', () {
      expect(sideOf(east, null), 1);
      expect(sideOf(const [LL(43.6, -116.3)], Heading.west), 1);
    });
  });

  group('directions', () {
    test('a short and a long form are one direction; None, Unknown and empty are none', () {
      for (final w in ['West', 'Westbound', 'westbound', ' W ']) {
        expect(headingOf(w), Heading.west, reason: w);
      }
      expect(headingOf('Northbound'), Heading.north);
      for (final n in ['None', 'Unknown', '', 'undefined', 'Both Directions', null, 4]) {
        expect(headingOf(n), isNull, reason: '$n');
      }
    });
  });

  group('the GeoJSON of the events', () {
    test('a closure: a line beside the road, a chip in the middle; a crash: its chip only; work: a work line; a detour: its own line', () {
      final line = decodePolyline(kLine);
      final json = roadEventsGeoJson([
        ev('c', RoadEventKind.closure, line: line, heading: Heading.west, full: true, detour: decodePolyline(kDetour)),
        ev('x', RoadEventKind.crash),
        ev('w', RoadEventKind.work, line: line),
      ]);
      final f = (json['features'] as List).cast<Map<String, dynamic>>();
      Map<String, dynamic> props(Map<String, dynamic> x) => x['properties'] as Map<String, dynamic>;
      expect(f.where((x) => props(x)['role'] == 'closure').length, 1);
      expect(f.where((x) => props(x)['role'] == 'work').length, 1);
      expect(f.where((x) => props(x)['role'] == 'detour').length, 1);
      expect(f.where((x) => props(x)['role'] == 'chip').map((x) => props(x)['icon']), [kRoadChipClosure, kRoadChipCrash, kRoadChipWork]);
      expect(f.where((x) => props(x)['id'] == 'x').length, 1, reason: 'a crash with no line has its chip only');
      final closure = f.firstWhere((x) => props(x)['role'] == 'closure');
      expect(props(closure)['side'], isIn([1, -1]));
      expect((closure['geometry'] as Map)['type'], 'LineString');
      // the chip of a stretch is in its middle, in longitude, latitude order
      final chip = f.firstWhere((x) => props(x)['id'] == 'c' && props(x)['role'] == 'chip');
      final at = ((chip['geometry'] as Map)['coordinates'] as List).cast<double>();
      expect(at[1], closeTo(43.6, 0.05));
      expect(at[0], closeTo(-116.28, 0.05));
    });

    test('a crash that closes every lane is also drawn as a closure line; an out-of-date copy is dimmed, never dropped', () {
      final line = decodePolyline(kLine);
      final json = roadEventsGeoJson([ev('x', RoadEventKind.crash, line: line, full: true, stale: true)]);
      final roles = [for (final f in json['features'] as List) ((f as Map)['properties'] as Map)['role']];
      expect(roles, ['closure', 'chip']);
      expect([for (final f in json['features'] as List) ((f as Map)['properties'] as Map)['dim']], [true, true]);
    });

    test('the tapped event is marked on its chip and lines', () {
      final line = decodePolyline(kLine);
      final json = roadEventsGeoJson([ev('a', RoadEventKind.closure, line: line), ev('b', RoadEventKind.closure, line: line)], selectedId: 'b');
      for (final f in json['features'] as List) {
        final p = (f as Map)['properties'] as Map;
        expect(p['sel'], p['id'] == 'b');
      }
    });

    test('an event with no place is not drawn, and the JSON is plain data', () {
      expect(jsonEncode(roadEventsGeoJson(const [])), '{"type":"FeatureCollection","features":[]}');
    });
  });

  group('the style layers', () {
    test('lines sit beside the road (line-offset), dashed for work and detours, in the palette\'s roles, with the route\'s casing', () {
      for (final id in CacheThemeId.values) {
        final p = mapPaletteFor(id);
        final layers = {for (final l in roadEventLayers(p)) l['id'] as String: l};
        expect(layers.keys, [kRoadEventCasing, kRoadEventClosure, kRoadEventWork, kRoadEventDetour, kRoadEventSelected, kRoadEventChips]);
        expect(layers[kRoadEventClosure]!['paint']['line-color'], p.css('eventClosure'));
        expect(layers[kRoadEventWork]!['paint']['line-color'], p.css('eventWork'));
        expect(layers[kRoadEventWork]!['paint']['line-dasharray'], isNotNull);
        expect(layers[kRoadEventDetour]!['paint']['line-color'], p.css('route'));
        expect(layers[kRoadEventDetour]!['paint']['line-dasharray'], isNotNull);
        expect(layers[kRoadEventCasing]!['paint']['line-color'], p.css('routeCasing'));
        for (final l in [kRoadEventCasing, kRoadEventClosure, kRoadEventWork, kRoadEventDetour]) {
          expect(jsonEncode(layers[l]!['paint']['line-offset']), contains('"side"'), reason: '$l is offset to its side');
          expect(jsonEncode(layers[l]!['paint']['line-offset']), contains('zoom'));
        }
        expect(layers[kRoadEventDetour]!['minzoom'], greaterThan(layers[kRoadEventClosure]!['minzoom'] as num), reason: 'detours show from a closer zoom');
        expect(layers[kRoadEventChips]!['type'], 'symbol');
        expect(layers[kRoadEventChips]!['layout']['icon-image'], ['get', 'icon']);
      }
    });

    test('the style has the source, draws the events above every base-map layer and under the route and the pins', () {
      final style = buildMapStyle(
        palette: mapPaletteFor(CacheThemeId.light),
        omtTemplate: const {
          'layers': [
            {'id': 'road_motorway', 'type': 'line', 'source': 'x'},
            {'id': 'roads_labels', 'type': 'symbol', 'source': 'x'},
          ],
        },
        layers: const [],
        tilesUrl: (d) => '',
        glyphsUrl: 'file:///f/{fontstack}/{range}.pbf',
      );
      expect((style['sources'] as Map).containsKey(kRoadEventSource), isTrue);
      final ids = [for (final l in style['layers'] as List) (l as Map)['id'] as String];
      final label = ids.indexOf('roads_labels');
      expect(ids.indexOf(kRoadEventClosure), greaterThan(label), reason: 'above the road names, so the line is never under a label');
      expect(ids.indexOf(kRoadEventChips), lessThan(ids.indexOf(kRouteRoad)));
    });
  });

  group('the chips', () {
    test('the closure and crash chips use eventClosure, work uses eventWork, and each kind has its own image name', () {
      expect(roadEventRole(RoadEventKind.closure), 'eventClosure');
      expect(roadEventRole(RoadEventKind.crash), 'eventClosure');
      expect(roadEventRole(RoadEventKind.work), 'eventWork');
      expect({for (final k in RoadEventKind.values) roadChipImage(k)}.length, 3);
    });

    test('adding them gives the style three images, and one that fails does not stop the others', () async {
      final added = <String>[];
      final log = <String>[];
      await addRoadChips(
        (n, png) async => added.add(n),
        mapPaletteFor(CacheThemeId.light),
        ratio: 1,
        log: log.add,
        render: (k, p, {double ratio = 3}) async {
          if (k == RoadEventKind.crash) throw StateError('no glyph');
          return Uint8List.fromList([1]);
        },
      );
      expect(added, [kRoadChipClosure, kRoadChipWork]);
      expect(log.single, contains('road-chip-crash'));
    });
  });

  group('reading what the sources stored', () {
    LiveItem item511(String key, {Map<String, dynamic> app = const {}, Map<String, String> fields = const {}, ({double lat, double lon})? point = (lat: 43.6049, lon: -116.2809), String label = 'I-84: Bridge repair'}) =>
        LiveItem(address: 'live:idaho511-events/at:43.6,-116.3/$key', label: label, fields: fields, app: app, point: point);

    test('a 511 closure: the stretch, the detour, the direction, the times, the detour steps', () {
      final e = roadEventFrom511(
        item511('s1', app: {'type': 'closures', 'full': true, 'road': 'I-84', 'line': kLine, 'detour': kDetour, 'steps': ['Leave at the exit.', 'Rejoin after.'], 'start': 1795370000, 'until': 1795456400}, fields: {'Direction': 'Westbound', 'Details': 'Closed.'}),
        sourceId: 'idaho511-events',
        credit: 'Road events: Idaho 511',
      )!;
      expect(e.id, 'idaho511-events/s1');
      expect(e.kind, RoadEventKind.closure);
      expect(e.fullClosure, isTrue);
      expect(e.heading, Heading.west);
      expect(e.line.length, greaterThan(2));
      expect(e.detour.length, greaterThan(2));
      expect(e.detourSteps, ['Leave at the exit.', 'Rejoin after.']);
      expect(e.startUnix, 1795370000);
      expect(e.endUnix, 1795456400);
      expect(e.road, 'I-84');
    });

    test('a feed\'s placeholders are not shown as facts: "No Data" lanes and "none" severity are dropped, real values kept', () {
      final e = roadEventFrom511(
        item511('ph', app: {'type': 'roadwork', 'road': 'US-20', 'line': kLine}, fields: {
          'Lanes affected': 'No Data',
          'Severity': 'none',
          'Direction': 'Westbound',
          'Cause': '  UNKNOWN ',
          'Comment': '',
          'Detail': 'None',
          'Details': 'Work on the shoulder on US-20 Westbound.',
          'Starts': '2026-10-01 08:00',
        }),
        sourceId: 'idaho511-events',
        credit: 'Road events: Idaho 511',
      )!;
      expect(e.fields.keys.toSet(), {'Direction', 'Details', 'Starts'});
      final d = roadCardData(e);
      expect(d.lines.map((l) => l.text), ['Starts 2026-10-01 08:00', 'Work on the shoulder on US-20 Westbound.']);
      expect(d.subtitle, 'Road work · Westbound');
      final real = roadEventFrom511(item511('rv', app: {'type': 'roadwork', 'line': kLine}, fields: {'Lanes affected': 'Right lane', 'Severity': 'major', 'Details': 'No data was lost; none of the lanes are closed.'}), sourceId: 's', credit: '')!;
      expect(real.fields, {'Lanes affected': 'Right lane', 'Severity': 'major', 'Details': 'No data was lost; none of the lanes are closed.'});
      expect(roadCardData(real).lines.map((l) => l.text), ['Right lane', 'major', 'No data was lost; none of the lanes are closed.']);
    });

    test('the same markers are dropped for a WZDx work zone, and the set is whole-value and case-insensitive', () {
      final w = roadEventFromWzdx(
        LiveItem(address: 'live:wz/at:1/a', label: 'I-84', fields: {'Lanes': 'undefined', 'Details': 'Paving.'}, app: {'geom': {'type': 'Point', 'coordinates': [-116.28, 43.6]}}, point: (lat: 43.6, lon: -116.28)),
        sourceId: 'wz',
        credit: '',
      )!;
      expect(w.fields, {'Details': 'Paving.'});
      for (final m in ['No Data', 'NO DATA', ' none ', 'None', 'Unknown', 'undefined', '', '  ']) {
        expect(isNoValue(m), isTrue, reason: '"$m"');
      }
      for (final r in ['Right lane', 'All lanes', 'Major', 'Moderate', 'No data available for the east side', 'None of the lanes']) {
        expect(isNoValue(r), isFalse, reason: r);
      }
      expect(isNoValue(null), isTrue);
    });

    test('the field variations: a string detour, a zero end, "true" or 1 for full, a polyline that does not decode, no direction, a new type', () {
      final nl = roadEventFrom511(item511('nl', app: {'type': 'roadwork', 'full': 'true', 'steps': 'One string.', 'until': 0, 'line': kLine}, fields: const {}), sourceId: 's', credit: '')!;
      expect(nl.detourSteps, ['One string.']);
      expect(nl.endUnix, isNull, reason: 'a zero end is no end, never a 1970 date');
      expect(nl.fullClosure, isTrue);
      expect(nl.heading, isNull);
      final bad = roadEventFrom511(item511('b', app: {'type': 'closures', 'line': 'not a polyline \u0001', 'full': 1}), sourceId: 's', credit: '')!;
      expect(bad.line, isEmpty, reason: 'a polyline that does not decode is dropped');
      expect(bad.geometry.length, 1, reason: 'the event keeps its point');
      expect(bad.fullClosure, isTrue);
      final other = roadEventFrom511(item511('o', app: {'type': 'somethingNew'}), sourceId: 's', credit: '')!;
      expect(other.kind, RoadEventKind.crash, reason: 'a new type on one site never hides the event');
      expect(roadEventFrom511(item511('p', point: null, app: {'type': 'closures'}), sourceId: 's', credit: ''), isNull, reason: 'no place to draw');
      expect(kindOf511('accidentsAndIncidents', false), RoadEventKind.crash);
      expect(kindOf511('roadwork', false), RoadEventKind.work);
      expect(kindOf511('mystery', true), RoadEventKind.closure);
    });

    test('a WZDx work zone: a line or a point, the impact, the direction and the dates', () {
      LiveItem z(Map<String, dynamic> geom) => LiveItem(
        address: 'live:wzdx-idaho/at:43.6,-116.3/wz-1',
        label: 'I-84 eastbound',
        point: (lat: 43.6049, lon: -116.2809),
        app: {'geom': geom, 'impact': 'all-lanes-closed', 'dir': 'eastbound', 'start': '2026-11-20T12:00:00Z', 'until': '2026-11-30T12:00:00Z', 'road': ['I-84']},
      );
      final line = roadEventFromWzdx(
        z({'type': 'LineString', 'coordinates': [[-116.2809, 43.6049], [-116.2840, 43.6050], [-116.2900, 43.6052]]}),
        sourceId: 'wzdx-idaho',
        credit: 'Road work: Idaho DOT',
      )!;
      expect(line.kind, RoadEventKind.work);
      expect(line.source, RoadEventSource.workZone);
      expect(line.line.length, 3);
      expect(line.heading, Heading.east);
      expect(line.fullClosure, isTrue);
      expect(line.road, 'I-84');
      expect(line.endUnix! - line.startUnix!, 10 * 86400);
      final point = roadEventFromWzdx(z({'type': 'Point', 'coordinates': [-116.28, 43.65]}), sourceId: 'w', credit: '')!;
      expect(point.line, isEmpty);
      expect(point.geometry.length, 1);
    });
  });

  group('the event card', () {
    test('says the road, the kind and direction, what the source gave and the credit with the age; a field the site lacks is left out', () {
      final e = ev(
        'a',
        RoadEventKind.closure,
        line: decodePolyline(kLine),
        heading: Heading.west,
        full: true,
        age: '40 minutes old',
        fields: {'Starts': '2026-11-22 11:30', 'Planned end': '2026-11-23 11:30', 'Details': 'Closed for bridge deck repair.'},
        steps: ['Leave at the exit before the closure.', 'Rejoin after it.'],
      );
      final d = roadCardData(e);
      expect(d.title, 'I-84');
      expect(d.subtitle, 'Road closure · Westbound');
      expect(d.lines.first.text, 'All lanes closed');
      expect(d.lines.first.emphasis, isTrue);
      expect(d.lines.map((l) => l.text), containsAll(['Starts 2026-11-22 11:30', 'Ends 2026-11-23 11:30', 'Closed for bridge deck repair.']));
      expect(d.detour, ['Leave at the exit before the closure.', 'Rejoin after it.']);
      expect(d.credit, 'Road events: Idaho 511 · Updated 40 minutes ago');
      // a crash with no detour, no end, no description: only what it has, never "no detour"
      final crash = roadCardData(ev('b', RoadEventKind.crash, fields: {'Lanes affected': 'Right lane'}));
      expect(crash.subtitle, 'Crash or incident');
      expect(crash.lines.map((l) => l.text), ['Right lane']);
      expect(crash.detour, isEmpty);
      expect(crash.lines.map((l) => l.text.toLowerCase()).join(), isNot(contains('no detour')));
    });

    test('a copy past its validity says so with its age', () {
      expect(roadAgeWords('5 hours old', stale: true), 'Out of date, last updated 5 hours ago');
      expect(roadAgeWords('5 hours old', stale: false), 'Updated 5 hours ago');
      expect(roadAgeWords('less than a minute old', stale: false), 'Updated less than a minute ago');
      expect(roadAgeWords(null, stale: false), '');
      expect(roadCardData(ev('a', RoadEventKind.work, stale: true, age: '5 hours old')).credit, contains('Out of date, last updated 5 hours ago'));
    });

    testWidgets('is drawn in the place card\'s frame, with a close button', (tester) async {
      var closed = false;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: RoadEventCard(event: ev('a', RoadEventKind.closure, heading: Heading.west, full: true, steps: ['Take the frontage road.']), onClose: () => closed = true))),
      ));
      expect(find.byKey(const ValueKey('road-event-card')), findsOneWidget);
      expect(find.text('I-84'), findsOneWidget);
      expect(find.text('Road closure · Westbound'), findsOneWidget);
      expect(find.text('All lanes closed'), findsOneWidget);
      expect(find.text('Take the frontage road.'), findsOneWidget);
      expect(find.text('Road events: Idaho 511'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('road-event-card-close')));
      expect(closed, isTrue);
    });
  });

  group('which event a tap chooses', () {
    final events = [
      ev('a', RoadEventKind.work),
      ev('b', RoadEventKind.closure, full: true),
      ev('c', RoadEventKind.closure),
    ];
    test('a full closure wins, then the nearest (the first the query gives)', () {
      expect(pickEvent(['a', 'c', 'b'], events), 'b');
      expect(pickEvent(['c', 'a'], events), 'c');
      expect(pickEvent(['zzz'], events), isNull);
      expect(pickEvent(const [], events), isNull);
    });
  });
}
