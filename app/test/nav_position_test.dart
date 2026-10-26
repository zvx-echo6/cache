import 'dart:async';

import 'package:cache/nav/nav_position.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

Position pos(double lat, double lon) => Position(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime(2026, 10, 26, 12),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

void main() {
  late List<StreamController<Position>> made;
  late GeolocatorNavSource source;

  setUp(() {
    made = [];
    source = GeolocatorNavSource(positions: (settings) {
      final c = StreamController<Position>();
      made.add(c);
      return c.stream;
    });
  });

  test('a fix from the position service reaches the guidance stream', () async {
    final fixes = <double>[];
    source.start(title: 't', text: 'x').listen((f) => fixes.add(f.lat));
    made.single.add(pos(42.5, -113.8));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(fixes, [42.5]);
  });

  test('starting again while a stream runs replaces it: the old one is let go, the new one stays open and keeps delivering', () async {
    final first = <double>[];
    final second = <double>[];
    source.start(title: 't', text: 'x').listen((f) => first.add(f.lat));
    final s2 = source.start(title: 't', text: 'y')..listen((f) => second.add(f.lat));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(made, hasLength(2));
    expect(made[0].hasListener, isFalse, reason: 'the old position stream was cancelled');
    expect(made[1].hasListener, isTrue, reason: 'the new one was not cancelled by the old one finishing');
    made[1].add(pos(42.6, -113.7));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(second, [42.6]);
    expect(first, isEmpty);
    expect(s2, isNotNull);
  });

  test('stop lets go of the position stream, so the service ends with guidance', () async {
    source.start(title: 't', text: 'x').listen((_) {});
    expect(made.single.hasListener, isTrue);
    await source.stop();
    expect(made.single.hasListener, isFalse);
    await source.stop(); // safe twice
  });
}
