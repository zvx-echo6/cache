import 'package:cache/nav/units.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const us = Fmt(UnitSystem.imperial);
  const si = Fmt(UnitSystem.metric);

  test('units follow the phone region: miles for the United States and the other mile countries', () {
    expect(unitsForLocale(const Locale('en', 'US')), UnitSystem.imperial);
    expect(unitsForLocale(const Locale('en', 'GB')), UnitSystem.imperial);
    expect(unitsForLocale(const Locale('de', 'DE')), UnitSystem.metric);
    expect(unitsForLocale(const Locale('en')), UnitSystem.metric);
  });

  test('imperial distances', () {
    expect(us.distance(20), '70 ft');
    expect(us.distance(90), '300 ft');
    expect(us.distance(300), '0.2 mi');
    expect(us.distance(800), '0.5 mi');
    expect(us.distance(5000), '3.1 mi');
    expect(us.distance(24600), '15 mi');
  });

  test('metric distances', () {
    expect(si.distance(20), '20 m');
    expect(si.distance(240), '250 m');
    expect(si.distance(1500), '1.5 km');
    expect(si.distance(24600), '25 km');
  });

  test('durations', () {
    expect(us.duration(20), '1 min');
    expect(us.duration(600), '10 min');
    expect(us.duration(3600), '1 h');
    expect(us.duration(5100), '1 h 25 min');
    expect(us.duration(90000), '1 d 1 h');
    expect(us.duration(86400 * 2), '2 d');
  });

  test('heights', () {
    expect(us.height(30), '98 ft');
    expect(si.height(30), '30 m');
  });

  test('spoken distances are the ones a person would say', () {
    expect(us.spoken(805), 'half a mile');
    expect(us.spoken(1609), '1 mile');
    expect(us.spoken(3300), '2 miles');
    expect(us.spoken(1200), 'three quarters of a mile');
    expect(us.spoken(300), '1000 feet');
    expect(us.spoken(90), '300 feet');
    expect(us.spoken(25), '100 feet');
    expect(si.spoken(800), '800 meters');
    expect(si.spoken(300), '300 meters');
    expect(si.spoken(90), '100 meters');
    expect(si.spoken(1500), '1.5 kilometers');
    expect(si.spoken(2000), '2 kilometers');
    expect(us.spokenDuration(4500), '1 hour 15 minutes');
    expect(us.spokenDuration(1200), '20 minutes');
    expect(us.spokenDuration(60), '1 minute');
    expect(us.spokenHeight(30), '100 feet');
    expect(si.spokenHeight(30), '30 meters');
  });

  test('compass words and the clock', () {
    expect(cardinalWord('NE'), 'northeast');
    expect(cardinalWord('W'), 'west');
    expect(cardinalWord(null), '');
    expect(clockTime(DateTime(2026, 10, 26, 15, 5)), '3:05 PM');
    expect(clockTime(DateTime(2026, 10, 26, 0, 30)), '12:30 AM');
    expect(clockTime(DateTime(2026, 10, 26, 12, 0)), '12:00 PM');
  });
}
