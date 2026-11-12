import 'package:cache/weather/catalogue.dart';
import 'package:cache/weather/connector.dart';
import 'package:cache/weather/live_view.dart';
import 'package:cache/weather/place_alerts.dart';
import 'package:cache/weather/place_summary.dart';
import 'package:cache/weather/places.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/weather_fakes.dart';
import 'support/weather_screen_kit.dart';

// What the Weather screen says about one place, worked out from stored data alone: the order of "Happening nearby" and the top
// card's picks. No widgets here; the screen's own tests are in weather_screen_test.dart.

const _here = WatchPlace(id: 'here', kind: PlaceKind.here, name: 'Where I am', subtitle: '', lat: 42.54, lon: -113.79, key: kHereKey);

Connector _source(String id, String category) =>
    Connector.parse(miniDefinition(id), entry: CatalogueEntry.fromJson(entry(id, category, id)), origin: const Origin.catalogue('cache-connectors', 'Cache connectors'));

final _forecast = _source('openmeteo-forecast', 'weather');
final _nws = _source('nws-alerts-point', 'alerts');
final _ipaws = _source('ipaws-alerts-near', 'alerts');
final _incidents = _source('wfigs-incidents-near', 'fire');
final _perimeters = _source('wfigs-perimeters-near', 'fire');
final _detections = _source('firms-viirs-near', 'fire');
final _quakes = _source('usgs-quakes-near', 'earthquakes');

final _noon = DateTime(2026, 10, 26, 12);

SourceView _view(Connector c, List<Map<String, dynamic>> items, {DateTime? fetched, bool expired = false, bool missing = false}) => SourceView(
  source: c,
  place: _here,
  items: [for (final j in items) LiveItem.fromJson(j)],
  fetchedAt: (fetched ?? _noon.subtract(const Duration(minutes: 12))).toIso8601String(),
  expired: expired,
  missing: missing,
);

List<String> _labels(List<NearbyEvent> events) => [for (final e in events) e.item.label];

PlaceSummary _summary(List<SourceView> views, {bool pending = false}) =>
    PlaceSummary.of(place: _here, views: views, enabled: [for (final v in views) v.source], clock: _noon, pending: pending);

void main() {
  final sent = _noon.subtract(const Duration(hours: 1));
  final ends = _noon.add(const Duration(hours: 9));

  group('Happening nearby: the order', () {
    test('serious alerts by severity, then serious fires nearest first; then other alerts; then other fires nearest first; then one row per other source', () {
      final n = nearbyOf(_here, [
        // as the Weather Service lists them: by severity
        _view(_nws, [
          nwsAlert('a1', 'Red Flag Warning', 'severe', sent, ends, 'Tamber County'),
          nwsAlert('a2', 'Wind Advisory', 'moderate', sent, ends, 'Tamber County'),
          nwsAlert('a3', 'Special Weather Statement', null, sent, ends, 'Tamber County'),
        ]),
        _view(_ipaws, [
          ipawsAlert('e1', 'Evacuation order for the Tamber Flat area', 'Evacuation Immediate', 'extreme', sent, ends, by: 'Tamber County Sheriff', area: 'Tamber Flat'),
          ipawsAlert('e2', 'Be ready to leave: Alder Valley', 'Evacuation Warning', 'moderate', sent, ends, by: 'Tamber County Sheriff', area: 'Alder Valley'),
        ]),
        // as the incident source lists them: by size, not by distance
        _view(_incidents, [
          fireItem('f1', 'East Fork', 31, '31 mi N'),
          fireItem('f2', 'Tamber Flat', 6.2, '6.2 mi NE'),
          fireItem('f3', 'Rock Creek', 0, 'inside the area'),
          fireItem('f4', 'Harrow', 120, '120 mi S'),
          fireItem('f5', 'Wren', 60, '60 mi W'),
          fireItem('f6', 'Osprey Bend', 95, '95 mi E'),
          fireItem('f7', 'Quill', 80, '80 mi SE'),
        ]),
        _view(_quakes, [
          quakeItem('q1', 'M 2.1 - 14 km N of Wrenhollow', '2.1', 'today 9:14 AM', 38, '38 mi NW'),
          quakeItem('q2', 'M 2.4 - 30 km E of Wrenhollow', '2.4', 'yesterday 4:02 PM', 51, '51 mi N'),
        ]),
      ]);
      expect(_labels(n.serious), [
        'Evacuation order for the Tamber Flat area', // extreme
        'Red Flag Warning', // severe
        'Be ready to leave: Alder Valley', // an evacuation, whatever its severity
        'Rock Creek fire', // the place is inside its edge: as near as a fire gets
        'Tamber Flat fire', // within 10 miles
      ]);
      expect(n.serious.every((e) => e.serious), isTrue);
      expect(_labels(n.warnings), ['Wind Advisory', 'Special Weather Statement']);
      expect(_labels(n.fires), ['East Fork fire', 'Wren fire', 'Quill fire', 'Osprey Bend fire', 'Harrow fire'], reason: 'nearest first, whatever order the source lists them in');
      expect(n.ruled, isEmpty, reason: 'no place rule names earthquakes');
      expect([for (final v in n.sources) v.source.id], ['usgs-quakes-near'], reason: 'a kind the app cannot rank is one row, after everything ranked');
      expect(_labels(n.ranked), [..._labels(n.serious), ..._labels(n.warnings), ..._labels(n.fires)]);
      // of the fires that are not serious, the nearest three are listed and the rest wait behind one row
      expect(_labels(n.listed), [..._labels(n.serious), 'Wind Advisory', 'Special Weather Statement', 'East Fork fire', 'Wren fire', 'Quill fire']);
      expect(_labels(n.moreFires), ['Osprey Bend fire', 'Harrow fire']);
    });

    test('the seriousness is the pop-ups\' own: a fire is serious within 10 miles (9.9), and not past them (10.1)', () {
      final n = nearbyOf(_here, [
        _view(_incidents, [fireItem('f1', 'Near', 9.9, '9.9 mi N'), fireItem('f2', 'Nearly', 10.1, '10.1 mi N')]),
      ]);
      expect(_labels(n.serious), ['Near fire']);
      expect(_labels(n.fires), ['Nearly fire']);
    });

    test('the same alert from the Weather Service and from FEMA is one row', () {
      final nws = nwsAlert('abc', 'Red Flag Warning', 'severe', sent, ends, 'Tamber County');
      final relayed = {...nws, 'address': 'live:ipaws-alerts-near/x/urn:oid:2.49.0.1.840.0.abc.001.1.IPAWS'};
      final n = nearbyOf(_here, [
        _view(_nws, [nws]),
        _view(_ipaws, [relayed]),
      ]);
      expect(_labels(n.ranked), ['Red Flag Warning']);
      expect(n.ranked.single.view.source.id, 'nws-alerts-point', reason: 'the first source\'s copy');
    });

    test('a fire and its mapped perimeter are one row', () {
      final n = nearbyOf(_here, [
        _view(_incidents, [fireItem('f1', 'East Fork', 31, '31 mi N')]),
        _view(_perimeters, [fireItem('p1', 'East Fork', 29, '29 mi N', source: 'wfigs-perimeters-near')]),
      ]);
      expect(_labels(n.ranked), ['East Fork fire']);
    });

    test('items of one source that share a name are one row, the nearest in front; a named fire is never lost among them', () {
      final n = nearbyOf(_here, [
        _view(_incidents, [fireItem('f1', 'East Fork', 31, '31 mi N')]),
        _view(_detections, [detectionItem(1, 44, '44 mi W'), detectionItem(2, 8, '8 mi NE'), detectionItem(3, 41, '41 mi W')]),
      ]);
      expect(_labels(n.serious), ['Satellite fire detection (high confidence)'], reason: 'its nearest detection is within reach');
      final group = n.serious.single;
      expect([for (final i in group.same) i.distance], ['8 mi NE', '41 mi W', '44 mi W']);
      expect(group.item.distance, '8 mi NE');
      expect(_labels(n.fires), ['East Fork fire']);
    });

    test('a place with its own rule: the kinds it names are ranked within its distance, and its distance is the fires\' reach', () {
      final views = [
        _view(_incidents, [fireItem('f1', 'Tamber Flat', 20, '20 mi NE')]),
        _view(_quakes, [
          quakeItem('q1', 'M 3.4 - far', '3.4', 'today 9:14 AM', 38, '38 mi NW'),
          quakeItem('q2', 'M 2.1 - near', '2.1', 'today 8:02 AM', 12, '12 mi N'),
        ]),
      ];
      const rule = PlaceAlertRule(mode: PlaceAlertMode.custom, miles: 25, kinds: {'fire', 'earthquakes'});
      final n = nearbyOf(_here, views, rule: rule);
      expect(_labels(n.serious), ['Tamber Flat fire'], reason: 'within the place\'s own 25 miles');
      expect(_labels(n.ruled), ['M 2.1 - near']);
      expect([for (final v in n.sources) v.source.id], ['usgs-quakes-near'], reason: 'the quake beyond the rule\'s distance is still behind the source\'s row');
      // the same data at a place without a rule
      final plain = nearbyOf(_here, views);
      expect(plain.serious, isEmpty);
      expect(_labels(plain.fires), ['Tamber Flat fire']);
      expect(plain.ruled, isEmpty);
      // a place whose pop-ups are off is listed like any other
      final off = nearbyOf(_here, views, rule: const PlaceAlertRule(mode: PlaceAlertMode.off));
      expect(_labels(off.ranked), _labels(plain.ranked));
    });

    test('a source nothing is downloaded for lists nothing', () {
      final n = nearbyOf(_here, [
        _view(_nws, const [], missing: true),
        _view(_quakes, const [], missing: true),
      ]);
      expect(n.ranked, isEmpty);
      expect([for (final v in n.sources) v.source.id], ['usgs-quakes-near'], reason: 'the row says it is not downloaded');
    });
  });

  group('the top card and the days', () {
    List<Map<String, dynamic>> stored({Duration nowAge = const Duration(minutes: 12)}) => [
      nowItem(_noon.subtract(nowAge), temperature: 45, feels: 41, wind: '8 mph NW, gusts 15 mph', conditions: 'partly cloudy'),
      ...sixteenDays(DateTime(2026, 10, 26)),
    ];

    test('a reading, today and sixteen days', () {
      final s = _summary([_view(_forecast, stored())]);
      expect(s.reading?.fields['Temperature'], '45 °F');
      expect(s.readingIsOld(_noon), isFalse);
      expect(s.now?.label, 'Mon Oct 26');
      expect(s.isToday(s.days.first), isTrue);
      expect(s.days, hasLength(16));
      expect(s.forecastExpired, isFalse);
    });

    test('a reading over an hour old says when it was taken; over three hours old it is not a reading of now', () {
      final old = _summary([_view(_forecast, stored(nowAge: const Duration(minutes: 90)))]);
      expect(old.reading, isNotNull);
      expect(old.readingIsOld(_noon), isTrue);
      // what the app kept is as the core gave it then: the core would leave this "Now" out by now
      final ended = _summary([_view(_forecast, stored(nowAge: const Duration(hours: 4)))], pending: true);
      expect(ended.reading, isNull, reason: 'no temperature is known for now');
      expect(ended.now?.label, 'Mon Oct 26', reason: 'the forecast for today stands in');
    });

    test('a kept copy from two days ago: the days that have passed are not listed, and today is today', () {
      final then = DateTime(2026, 10, 24, 9);
      final s = _summary([
        _view(_forecast, [nowItem(then, temperature: 60, feels: 60, wind: '2 mph N', conditions: 'clear sky'), ...sixteenDays(DateTime(2026, 10, 24))], fetched: then),
      ], pending: true);
      expect(s.reading, isNull);
      expect(s.days.first.label, 'Mon Oct 26');
      expect(s.days, hasLength(14));
      expect(s.now?.label, 'Mon Oct 26');
    });

    test('every day has passed', () {
      final s = _summary([_view(_forecast, const [], fetched: DateTime(2026, 10, 1), expired: true)]);
      expect(s.forecastExpired, isTrue);
      expect(s.days, isEmpty);
    });

    test('nothing downloaded yet', () {
      final s = _summary([_view(_forecast, const [], missing: true)]);
      expect(s.forecastOn, isTrue);
      expect(s.forecast, isNull);
      expect(s.anyStored, isFalse);
    });

    test('the calm line speaks only for what was checked, and only while the check is not too old', () {
      final quiet = _summary([_view(_nws, const []), _view(_incidents, const [])]);
      expect(quiet.calm, isTrue);
      expect(quiet.warningsChecked && quiet.firesChecked, isTrue);
      expect(quiet.checkedAt, _noon.subtract(const Duration(minutes: 12)));

      final alertsOnly = _summary([_view(_nws, const []), _view(_incidents, const [], missing: true)]);
      expect(alertsOnly.calm, isTrue);
      expect(alertsOnly.firesChecked, isFalse, reason: 'fires were not checked: the line must not speak for them');

      final first = _summary([_view(_nws, const [], missing: true), _view(_incidents, const [], missing: true)]);
      expect(first.calm, isFalse);
      expect(first.notChecked, isTrue);

      final old = _summary([_view(_nws, const [], expired: true, fetched: _noon.subtract(const Duration(days: 2))), _view(_incidents, const [], expired: true, fetched: _noon.subtract(const Duration(days: 2)))]);
      expect(old.calm, isFalse, reason: 'a check two days old cannot say nothing is happening now');
      expect(old.tooOld, isTrue);

      final busy = _summary([_view(_nws, [nwsAlert('a2', 'Wind Advisory', 'moderate', sent, ends, 'Tamber County')]), _view(_incidents, const [])]);
      expect(busy.calm, isFalse);
    });
  });
}
