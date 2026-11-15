import 'package:cache/nav/street_names.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const name = StreetName('Lakeside Boulevard');
  const other = StreetName('Lakeview Drive');
  const business = StreetName('US 99 Bus', isRouteNumber: true);
  const highway = StreetName('SH 99', isRouteNumber: true);

  group('the road', () {
    test('a name and a route number: the name first, the number after it on screen, the name alone spoken', () {
      // The map lists the number first; the flag decides, not the order.
      expect(shownRoad(const [business, name]), 'Lakeside Boulevard (US 99 Bus)');
      expect(spokenRoad(const [business, name]), 'Lakeside Boulevard');
      expect(shownRoad(const [name, business]), 'Lakeside Boulevard (US 99 Bus)');
    });

    test('only a number keeps the number, only a name keeps the name, two names keep the first', () {
      expect(shownRoad(const [highway]), 'SH 99');
      expect(spokenRoad(const [highway]), 'SH 99');
      expect(shownRoad(const [name]), 'Lakeside Boulevard');
      expect(spokenRoad(const [name]), 'Lakeside Boulevard');
      expect(shownRoad(const [name, other]), 'Lakeside Boulevard');
      expect(spokenRoad(const [name, other]), 'Lakeside Boulevard');
      expect(shownRoad(const []), isNull);
      expect(spokenRoad(const []), isNull);
    });

    test('two numbers and no name keep both numbers, on screen and spoken; with a name, the first number goes in the brackets', () {
      const second = StreetName('SH 98', isRouteNumber: true);
      expect(shownRoad(const [second, highway]), 'SH 98/SH 99');
      expect(spokenRoad(const [second, highway]), 'SH 98/SH 99');
      const text = 'Turn right onto SH 98/SH 99.';
      expect(instructionWith(text, const [second, highway], const [], shownRoad), text);
      expect(instructionWith(text, const [second, highway], const [], spokenRoad), text);
      expect(shownRoad(const [second, highway, name]), 'Lakeside Boulevard (SH 98)');
      expect(spokenRoad(const [second, highway, name]), 'Lakeside Boulevard');
    });
  });

  group('the instruction', () {
    test('the street part is chosen by the rule, the rest stays as the router wrote it', () {
      const turn = 'Turn left onto US 99 Bus/Lakeside Boulevard.';
      expect(instructionWith(turn, const [business, name], const [], shownRoad), 'Turn left onto Lakeside Boulevard (US 99 Bus).');
      expect(instructionWith(turn, const [business, name], const [], spokenRoad), 'Turn left onto Lakeside Boulevard.');
      expect(instructionWith('Turn right onto SH 99.', const [highway], const [], shownRoad), 'Turn right onto SH 99.');
      expect(instructionWith('Drive east on Lakeside Boulevard/Lakeview Drive.', const [name, other], const [], shownRoad), 'Drive east on Lakeside Boulevard.');
      // No names, or names the text does not hold: as it is.
      expect(instructionWith('Turn left.', const [], const [], shownRoad), 'Turn left.');
      expect(instructionWith('You have arrived at your destination.', const [business, name], const [], shownRoad), 'You have arrived at your destination.');
    });

    test('the names where the maneuver starts and the ones it continues on are each chosen by the rule', () {
      const text = 'Turn right onto US 99 Bus/Lakeside Boulevard. Continue on SH 99.';
      expect(instructionWith(text, const [highway], const [business, name], shownRoad), 'Turn right onto Lakeside Boulevard (US 99 Bus). Continue on SH 99.');
      expect(instructionWith(text, const [highway], const [business, name], spokenRoad), 'Turn right onto Lakeside Boulevard. Continue on SH 99.');
      // The same road at both ends: each stretch is replaced once, in order.
      const same = 'Bear left onto US 99 Bus/Lakeside Boulevard. Continue on US 99 Bus/Lakeside Boulevard.';
      expect(instructionWith(same, const [business, name], const [business, name], spokenRoad), 'Bear left onto Lakeside Boulevard. Continue on Lakeside Boulevard.');
    });
  });

  group('from the core', () {
    test('a maneuver carries the map\'s flags; one from a core without them reads its names as names', () {
      final m = ProgressManeuver.fromJson({
        'index': 1, 'kind': 'road', 'type': 'right', 'instruction': 'Turn right onto SH 99. Continue on US 99 Bus/Lakeside Boulevard.',
        'street_names': ['US 99 Bus', 'Lakeside Boulevard'], 'lat': 0, 'lon': 0, 'distance_m': 100,
        'streets': [{'text': 'US 99 Bus', 'is_route_number': true}, {'text': 'Lakeside Boulevard', 'is_route_number': false}],
        'begin_streets': [{'text': 'SH 99', 'is_route_number': true}],
      });
      expect(m.streets, const [business, name]);
      expect(m.beginStreets, const [highway]);
      expect(m.shownInstruction, 'Turn right onto SH 99. Continue on Lakeside Boulevard (US 99 Bus).');
      expect(m.spokenInstruction, 'Turn right onto SH 99. Continue on Lakeside Boulevard.');
      expect(m.shownRoadName, 'Lakeside Boulevard (US 99 Bus)');

      final old = Maneuver.fromJson({'index': 1, 'type': 'left', 'instruction': 'Turn left onto Road 1/Road 1a.', 'street_names': ['Road 1', 'Road 1a']});
      expect(old.streets, const [StreetName('Road 1'), StreetName('Road 1a')]);
      expect(old.beginStreets, isEmpty);
      expect(old.shownRoadName, 'Road 1');
      expect(old.shownInstruction, 'Turn left onto Road 1.');
    });

    test('a main road reads as the turns do', () {
      expect(majorRoadShown({'name': 'US 99 Bus', 'streets': [{'text': 'US 99 Bus', 'is_route_number': true}, {'text': 'Lakeside Boulevard', 'is_route_number': false}]}), 'Lakeside Boulevard (US 99 Bus)');
      expect(majorRoadShown({'name': 'Road 0'}), 'Road 0');
      expect(majorRoadShown({'name': ''}), isNull);
      expect(majorRoadShown(null), isNull);
    });
  });
}
