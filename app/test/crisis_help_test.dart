import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/crisis_card.dart';
import 'package:cache/screens/crisis_help.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'browse/fakes.dart' show FakeProbe;
import 'support/settings_rig.dart' show RigPositionSource;

void main() {
  late Directory dir;
  late LocationService location;
  late FakeBackend backend;
  late NavState nav;
  late AppCrisisHelp help;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('crisis-help');
    location = LocationService(source: RigPositionSource(), settingsDirOverride: dir)..fix = fixAt(42.56, -114.46);
    backend = FakeBackend();
    nav = NavState(backend: backend, location: location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
    final settings = AppSettings(settingsDirOverride: dir);
    help = AppCrisisHelp(
      nav: nav,
      location: location,
      policy: DataPolicy(settings: settings, probe: FakeProbe(ConnectionKind.wifi)),
      installedIds: () => const {},
      onOpenGuides: (_) {},
      onGetGuides: (_) {},
      onGetMap: (_) {},
      onDirections: (_, _) {},
    );
  });

  tearDown(() => nav.dispose());

  const category = MapPlace(id: 'category:emergency_room', type: 'category', name: 'Emergency room', kind: 'Emergency room', category: 'emergency_room', lat: 0, lon: 0);
  const er = MapPlace(
    id: 'place:osm:w1',
    type: 'place',
    name: "St. Luke's Magic Valley Regional Medical Center",
    kind: 'Emergency room',
    category: 'emergency_room',
    lat: 42.5531,
    lon: -114.4691,
    distanceM: 900,
    phone: '+1 208 814 1000',
  );

  void answer(List<MapPlace> results, {PlacesCoverage? places}) =>
      backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: results, places: places);

  test('a real emergency room with a name and a position is shown', () async {
    answer([category, er], places: const PlacesCoverage(installed: true, covers: true));
    final n = await help.nearestEr();
    expect(n.state, ErState.found);
    expect(n.place?.name, er.name);
  });

  test('the category row is never a place: with places here it is "No emergency room in your map data."', () async {
    answer([category], places: const PlacesCoverage(installed: true, covers: true));
    expect((await help.nearestEr()).state, ErState.noEr);
  });

  test('the category row is never a place: with no places on the phone it is "No offline map for this area."', () async {
    answer([category], places: const PlacesCoverage(installed: false, covers: false));
    expect((await help.nearestEr()).state, ErState.noMap);
    answer([category]);
    expect((await help.nearestEr()).state, ErState.noMap, reason: 'nothing said about places: none to trust');
    expect(isRealEmergencyRoom(category), isFalse);
    expect(isRealEmergencyRoom(er), isTrue);
  });
}
