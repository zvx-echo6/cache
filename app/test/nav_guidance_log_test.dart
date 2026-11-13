import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';

/// Guidance's lines in the app log: one a minute with what the minute had (fixes, the core's last answer, failures), and a
/// failing progress update logged the first time and then at most once a minute.

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

Future<void> settle([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late LocationService location;
  late FakeBackend backend;
  late FakeNavPosition gps;
  late NavState nav;
  late List<String> logged;
  late DebugPrintCallback oldPrint;
  var now = DateTime(2026, 10, 26, 12);
  final routeJson = fakeRouteJson(name: 'Destination');
  const dest = MapPlace(id: 'p:1', type: 'place', name: 'Destination', kind: 'Place', address: '', lat: 42.5, lon: -113.5, matched: 'name');

  NavState makeNav({Duration? every}) => NavState(
        backend: backend,
        location: location,
        speaker: FakeSpeaker(),
        positionSource: gps,
        fmt: const Fmt(UnitSystem.metric),
        clock: () => now,
        searchDebounce: const Duration(milliseconds: 5),
        meaningDebounce: const Duration(milliseconds: 25),
        guidanceLogEvery: every,
      );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('navlog');
    location = LocationService(source: _NoSource(), settingsDirOverride: dir);
    await location.init();
    backend = FakeBackend();
    gps = FakeNavPosition();
    now = DateTime(2026, 10, 26, 12);
    logged = [];
    oldPrint = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => logged.add(m ?? '');
    nav = makeNav();
  });

  tearDown(() {
    debugPrint = oldPrint;
    nav.dispose();
    location.dispose();
    dir.deleteSync(recursive: true);
  });

  MapProgress p(double f, {double offset = 0, bool off = false, int count = 0}) =>
      MapProgress.fromJson(fakeProgressJson(routeJson, f, offset: offset, offRoute: off, offCount: count));

  Fix fixNow(double lon, {double acc = 6}) => Fix(lat: 42.5, lon: lon, accuracyM: acc, time: now);

  Future<void> startGuidance() async {
    location.publish(fixAt(42.5, -113.8));
    backend.onRoute = (to, mode, from) async => MapRoute.fromJson(routeJson);
    await nav.openDirections(dest);
    await nav.start();
    await settle();
  }

  List<String> lines(String tag, String start) => [for (final l in logged) if (l.contains(' $tag $start')) l];
  List<String> minuteLines() => [for (final l in lines('INFO', 'Guidance: ')) if (l.contains(' fixes in ')) l];

  test('the minute line counts the fixes, gives the last fix and the core\'s last answer, and starts counting again', () async {
    backend.onProgress = (r, lat, lon) async => p(0.1, offset: 12);
    await startGuidance();
    expect(lines('INFO', 'Guidance: started'), hasLength(1));
    for (final lon in [-113.79, -113.78, -113.77]) {
      gps.controller.add(fixNow(lon));
      await settle();
    }
    now = now.add(const Duration(seconds: 60));
    nav.logGuidanceMinute();
    final first = minuteLines().single;
    expect(first, contains('Guidance: 3 fixes in 60s'));
    expect(first, contains('last fix 60 s old, accuracy 6 m'));
    expect(first, contains('on route true, off route false (0 fixes off), 12 m from the route'));
    expect(first, contains('0 progress errors'));
    expect(first, isNot(contains('42.5')), reason: 'no position goes into the log');

    // Nothing came in the next minute: the counts are zero and the ages say how old the last fix and answer are.
    now = now.add(const Duration(seconds: 60));
    nav.logGuidanceMinute();
    final second = minuteLines().last;
    expect(second, contains('Guidance: 0 fixes in 60s'));
    expect(second, contains('last fix 120 s old'));
    expect(second, contains('0 progress calls'));
  });

  test('an off-route answer is in the minute line', () async {
    backend.onProgress = (r, lat, lon) async => p(0.1);
    await startGuidance();
    backend.onRoute = (to, mode, from) async => MapRoute.fromJson(fakeRouteJson(id: 'r-new', name: 'Destination'));
    backend.onProgress = (r, lat, lon) async => p(0.12, offset: 200, off: true, count: 3);
    gps.controller.add(fixNow(-113.76));
    await settle(60);
    nav.logGuidanceMinute();
    final line = minuteLines().single;
    expect(line, contains('off route true (3 fixes off), 200 m from the route'));
    expect(line, contains('1 off-route answers'));
    expect(lines('INFO', 'Guidance: off the route, the new route'), hasLength(1));
  });

  test('a failing progress update is logged the first time, then at most once a minute, and counted in the minute line', () async {
    backend.onProgress = (r, lat, lon) async => throw const CacheSearchException('internal', 'core busy');
    await startGuidance();
    // the fix Start already had failed too
    expect(lines('ERROR', 'Guidance: a progress update failed'), hasLength(1));
    expect(lines('ERROR', 'Guidance: a progress update failed').single, endsWith('Guidance: a progress update failed: internal: core busy'));
    for (var i = 0; i < 4; i++) {
      now = now.add(const Duration(seconds: 5));
      gps.controller.add(fixNow(-113.79 + i * 0.001));
      await settle();
    }
    expect(lines('ERROR', 'Guidance: a progress update failed'), hasLength(1), reason: 'not one line per fix');
    now = now.add(const Duration(seconds: 45));
    gps.controller.add(fixNow(-113.78));
    await settle();
    final errors = lines('ERROR', 'Guidance: a progress update failed');
    expect(errors, hasLength(2));
    expect(errors.last, contains('(4 more since the last such line): internal: core busy'));

    nav.logGuidanceMinute();
    final line = minuteLines().single;
    expect(line, contains('Guidance: 5 fixes in 65s'));
    expect(line, contains('6 progress errors (first: internal: core busy)'));
    expect(line, contains('no progress answer'));
  });

  test('an error from the position stream is logged and counted; the stream goes on', () async {
    backend.onProgress = (r, lat, lon) async => p(0.1);
    await startGuidance();
    gps.controller.addError(StateError('no fix'));
    await settle();
    gps.controller.add(fixNow(-113.79));
    await settle();
    expect(lines('ERROR', 'Guidance: the position stream reported an error'), hasLength(1));
    nav.logGuidanceMinute();
    expect(minuteLines().single, allOf(contains('1 fixes in'), contains('1 position stream errors')));
  });

  test('a new route that could not be worked out is logged', () async {
    backend.onProgress = (r, lat, lon) async => p(0.12, offset: 200, off: true, count: 3);
    await startGuidance();
    backend.onRoute = (to, mode, from) async => throw const CacheSearchException('upstream_timeout', 'took too long');
    now = now.add(const Duration(seconds: 30));
    gps.controller.add(fixNow(-113.76));
    await settle(60);
    expect(lines('ERROR', 'Guidance: off the route, working out a new route failed'), hasLength(1));
    nav.logGuidanceMinute();
    expect(minuteLines().single, contains('re-routes failed'));
  });

  test('with a period the line comes by itself while guiding, once more when guidance ends, and then no more', () async {
    nav.dispose();
    nav = makeNav(every: const Duration(milliseconds: 40));
    backend.onProgress = (r, lat, lon) async => p(0.1);
    await startGuidance();
    await settle(130);
    expect(minuteLines().length, greaterThanOrEqualTo(2));
    await nav.end();
    final atEnd = minuteLines().length;
    await settle(130);
    expect(minuteLines().length, atEnd, reason: 'the timer stops with guidance');
  });

  test('without a period only the line at the end is written', () async {
    backend.onProgress = (r, lat, lon) async => p(0.1);
    await startGuidance();
    await settle(60);
    expect(minuteLines(), isEmpty);
    await nav.end();
    expect(minuteLines(), hasLength(1));
    await nav.end();
    expect(minuteLines(), hasLength(1), reason: 'ending twice writes one line');
  });
}
