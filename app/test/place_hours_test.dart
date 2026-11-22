import 'dart:convert';
import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/nav/hours_text.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/ui/place_card.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';

/// Real `opening_hours` values from the Idaho places pack and what the core reads from each (written by
/// cache_places/tests/hours_fixture.rs; the Rust test checks the file against the parser, this one the words and the answers).
const _fixturePath = '../packages/cache_search/native/cache_places/tests/data/opening_hours_fixture.json';

class _NoSource implements PositionSource {
  @override
  Future<LocationPermissionState> permission() async => LocationPermissionState.granted;
  @override
  Future<LocationPermissionState> requestPermission() async => LocationPermissionState.granted;
  @override
  Future<bool> serviceEnabled() async => true;
  @override
  Future<Fix> current() async => fixAt(42.5, -113.8);
  @override
  Stream<Fix> stream() => const Stream.empty();
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

List<Map<String, dynamic>> _fixture() => [for (final e in jsonDecode(File(_fixturePath).readAsStringSync()) as List) (e as Map).cast<String, dynamic>()];

List<List<List<int>>> _weekOf(Map<String, dynamic> e) => [
      for (final d in e['week'] as List) [for (final r in d as List) [for (final x in r as List) (x as num).toInt()]],
    ];

/// A place the way the core returns it for [raw]: from the fixture, so the week is the parser's.
MapPlace _place(String raw, {int? offset = -420, bool? exact}) {
  final e = _fixture().firstWhere((e) => e['raw'] == raw, orElse: () => throw StateError('$raw is not in the fixture'));
  return MapPlace(
    id: 'place:test', type: 'place', name: 'Test', kind: 'Pharmacy', lat: 42.56, lon: -114.46, matched: 'name', hours: raw,
    hoursWeek: e['week'] == null ? null : _weekOf(e), hoursExact: exact ?? e['exact'] != false, timezone: offset == null ? null : 'America/Boise', utcOffsetMin: offset,
  );
}

/// The instant when it is [y-m-d h:mi:s] at [offset] minutes from UTC.
DateTime _at(int y, int m, int d, int h, int mi, [int s = 0, int offset = -420]) => DateTime.utc(y, m, d, h, mi, s).subtract(Duration(minutes: offset));

const _kurts = 'Mo-Fr 09:00-19:00, Sa 10:00-17:00';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the hours in words', () {
    test('Kurt\'s Pharmacy, in 12 and 24 hour time', () {
      final p = _place(_kurts);
      expect(hoursViewFor(p, use24h: false)!.text, 'Mon–Fri 9 AM–7 PM · Sat 10 AM–5 PM');
      expect(hoursViewFor(p, use24h: true)!.text, 'Mon–Fri 09:00–19:00 · Sat 10:00–17:00');
    });

    test('24/7 is "Open 24 hours"', () {
      expect(hoursViewFor(_place('24/7'), use24h: false)!.text, 'Open 24 hours');
      expect(hoursViewFor(_place('24/7'), use24h: true)!.text, 'Open 24 hours');
    });

    test('the same hours every day are "Daily"; a half hour shows its minutes', () {
      expect(hoursText(List.generate(7, (_) => [[510, 1260]]), use24h: false), 'Daily 8:30 AM–9 PM');
      expect(hoursText(List.generate(7, (_) => [[510, 1260]]), use24h: true), 'Daily 08:30–21:00');
    });

    test('an overnight range ends at the next morning\'s time', () {
      // "Fr-Sa 18:00-02:00": Friday and Saturday evenings run to 2 in the morning.
      final List<List<List<int>>> week = [[], [], [], [], [[1080, 1560]], [[1080, 1560]], []];
      expect(hoursText(week, use24h: false), 'Fri–Sat 6 PM–2 AM');
      expect(hoursText(week, use24h: true), 'Fri–Sat 18:00–02:00');
    });

    test('noon, midnight, split days, days that are not next to each other', () {
      expect(clockText(720, use24h: false), '12 PM');
      expect(clockText(0, use24h: false), '12 AM');
      expect(clockText(1440, use24h: false), '12 AM');
      expect(clockText(1440, use24h: true), '00:00');
      expect(hoursText([[[480, 720], [780, 1020]], [], [[480, 720], [780, 1020]], [], [], [], <List<int>>[]], use24h: false), 'Mon, Wed 8 AM–12 PM, 1 PM–5 PM');
      expect(hoursText([[[0, 1440]], [[0, 1440]], [[0, 1440]], [[0, 1440]], [[0, 1440]], [[600, 1020]], []], use24h: false), 'Mon–Fri open 24 hours · Sat 10 AM–5 PM');
    });
  });

  group('open now', () {
    test('Kurt\'s Pharmacy on a Monday: just before and just after each boundary', () {
      final p = _place(_kurts);
      bool? at(int h, int mi, [int s = 0]) => hoursViewFor(p, use24h: false, now: _at(2026, 11, 23, h, mi, s))!.openNow;
      expect(at(8, 59, 59), false);
      expect(at(9, 0), true);
      expect(at(18, 59, 59), true);
      expect(at(19, 0), false);
      expect(at(3, 0), false);
    });

    test('Saturday and Sunday', () {
      final p = _place(_kurts);
      bool? at(int d, int h, int mi, [int s = 0]) => hoursViewFor(p, use24h: false, now: _at(2026, 11, d, h, mi, s))!.openNow;
      expect(at(21, 9, 59, 59), false); // Saturday before 10
      expect(at(21, 10, 0), true);
      expect(at(21, 16, 59, 59), true);
      expect(at(21, 17, 0), false);
      expect(at(22, 12, 0), false); // Sunday: closed all day
    });

    test('an overnight range belongs to the evening it starts on', () {
      final List<List<List<int>>> week = [[], [], [], [], [[1080, 1560]], [[1080, 1560]], []];
      const offset = -420;
      MapPlace p() => MapPlace(id: 'p', type: 'place', name: 'Bar', kind: 'Bar', lat: 42.5, lon: -114.4, hours: 'Fr-Sa 18:00-02:00', hoursWeek: week, utcOffsetMin: offset);
      bool? at(int d, int h, int mi, [int s = 0]) => hoursViewFor(p(), use24h: false, now: _at(2026, 11, d, h, mi, s))!.openNow;
      expect(at(20, 17, 59, 59), false); // Friday
      expect(at(20, 18, 0), true);
      expect(at(20, 23, 59, 59), true);
      expect(at(21, 0, 0), true); // Saturday just after midnight: still Friday's evening
      expect(at(21, 1, 59, 59), true);
      expect(at(21, 2, 0), false);
      expect(at(21, 18, 0), true);
      expect(at(22, 1, 59, 59), true); // Sunday morning: Saturday's evening
      expect(at(22, 2, 0), false);
      expect(at(23, 1, 0), false); // Monday morning: Sunday has none
    });

    test('24/7 is always open', () {
      expect(hoursViewFor(_place('24/7'), use24h: false, now: _at(2026, 11, 22, 3, 33))!.openNow, true);
    });

    test('it is read in the place\'s zone, not the phone\'s', () {
      // 16:00 UTC is 09:00 in Boise (UTC-7, open) and 08:00 on Pacific time (UTC-8, not yet open).
      final boise = _place(_kurts, offset: -420);
      final pacific = _place(_kurts, offset: -480);
      final now = DateTime.utc(2026, 11, 23, 16, 0);
      expect(hoursViewFor(boise, use24h: false, now: now)!.openNow, true);
      expect(hoursViewFor(pacific, use24h: false, now: now)!.openNow, false);
    });

    test('a different day in the zone than on the clock', () {
      // 03:00 UTC Tuesday is Monday 20:00 in Boise: Monday's hours are over.
      expect(hoursViewFor(_place(_kurts), use24h: false, now: DateTime.utc(2026, 11, 24, 3, 0))!.openNow, false);
      expect(hoursViewFor(_place(_kurts), use24h: false, now: DateTime.utc(2026, 11, 24, 1, 59))!.openNow, true); // Monday 18:59
    });

    test('nothing is said when the zone is not known, or the value is not exact', () {
      expect(hoursViewFor(_place(_kurts, offset: null), use24h: false, now: _at(2026, 11, 23, 12, 0))!.openNow, isNull);
      final p = _place(_kurts, exact: false);
      expect(hoursViewFor(p, use24h: false, now: _at(2026, 11, 23, 12, 0))!.openNow, isNull);
      expect(hoursViewFor(p, use24h: false)!.text, 'Mon–Fri 9 AM–7 PM · Sat 10 AM–5 PM', reason: 'the week is still shown');
    });
  });

  group('the raw fallback', () {
    test('Starbucks "sunrise-sunset" is shown as it is, with no Open or Closed', () {
      final v = hoursViewFor(_place('sunrise-sunset'), use24h: false, now: _at(2026, 11, 23, 12, 0))!;
      expect(v.text, 'sunrise-sunset');
      expect(v.openNow, isNull);
    });

    test('a place with no hours has no line', () {
      const p = MapPlace(id: 'p', type: 'place', name: 'X', kind: '', lat: 1, lon: 1);
      expect(hoursViewFor(p, use24h: false), isNull);
    });

    test('every value of the fixture: readable ones read in words and answer, the others stay as they are', () {
      final all = _fixture();
      expect(all.length, greaterThanOrEqualTo(200));
      var readable = 0, raw = 0;
      for (final e in all) {
        final p = _place(e['raw'] as String);
        for (final use24h in [false, true]) {
          final v = hoursViewFor(p, use24h: use24h, now: _at(2026, 11, 23, 12, 0))!;
          if (e['week'] != null) {
            if (!use24h) readable++;
            expect(v.text, isNot(equals(e['raw'])), reason: '${e['raw']} is read');
            expect(v.text, isNotEmpty);
            expect(v.text, isNot(contains('null')));
            expect(v.openNow, e['exact'] == false ? isNull : isNotNull, reason: e['raw'] as String);
          } else {
            if (!use24h) raw++;
            expect(v.text, e['raw']);
            expect(v.openNow, isNull);
          }
        }
        // Every minute of a week answers without throwing.
        if (e['week'] != null) {
          final w = _weekOf(e);
          for (var m = 0; m < 7 * 24 * 60; m += 37) {
            isOpenAt(w, DateTime.utc(2026, 11, 23).add(Duration(minutes: m)), -420);
          }
        }
      }
      expect(readable, greaterThan(100));
      expect(raw, greaterThan(20));
    });
  });

  group('on the place card', () {
    late Directory dir;
    late LocationService location;
    late NavState nav;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('place-hours');
      location = LocationService(source: _NoSource(), settingsDirOverride: dir);
      await location.init();
      location.publish(fixAt(42.5, -113.8));
      nav = NavState(backend: FakeBackend(), location: location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
    });
    tearDown(() {
      nav.dispose();
      location.dispose();
      dir.deleteSync(recursive: true);
    });

    Widget card(MapPlace p, {required bool use24h}) => MaterialApp(
          theme: buildTheme(CacheThemeId.light),
          home: MediaQuery(
            data: MediaQueryData(alwaysUse24HourFormat: use24h),
            child: Scaffold(body: PlaceCard(nav: nav, place: p, fmt: const Fmt(UnitSystem.imperial), onClose: () {})),
          ),
        );

    String hoursOnCard(WidgetTester t) => (t.widget(find.byKey(const ValueKey('place-card-hours'))) as Text).textSpan!.toPlainText();

    testWidgets('the card follows the phone\'s 12 or 24 hour setting', (tester) async {
      final p = _place(_kurts);
      await tester.pumpWidget(card(p, use24h: false));
      expect(hoursOnCard(tester), endsWith('Mon–Fri 9 AM–7 PM · Sat 10 AM–5 PM'));
      await tester.pumpWidget(card(p, use24h: true));
      expect(hoursOnCard(tester), endsWith('Mon–Fri 09:00–19:00 · Sat 10:00–17:00'));
    });

    testWidgets('a value that is not a weekly pattern is shown as it is, with no Open or Closed', (tester) async {
      await tester.pumpWidget(card(_place('sunrise-sunset'), use24h: false));
      expect(hoursOnCard(tester), 'sunrise-sunset');
      expect(find.textContaining('Open now'), findsNothing);
      expect(find.textContaining('Closed now'), findsNothing);
    });

    testWidgets('"Open now" or "Closed now" leads the line when it is known', (tester) async {
      await tester.pumpWidget(card(_place('24/7'), use24h: false));
      expect(hoursOnCard(tester), 'Open now · Open 24 hours');
    });
  });
}
