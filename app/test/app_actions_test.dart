import 'package:cache/actions/action_registry.dart';
import 'package:cache/actions/app_actions.dart';
import 'package:cache/weather/curated.dart';
import 'package:cache/weather/places.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';

class Fakes {
  final saved = <SavedPlaceRecord>[const SavedPlaceRecord(key: 'k1', name: 'Home', lat: 43.6, lon: -116.2, label: 'Boise')];
  final watched = <String>{'here'};
  final rowsOn = <String>{};
  bool available = true;
  bool missingKey = false;
  bool guiding = false;
  bool previewOk = true;
  final calls = <String>[];

  AppActions actions(ActionRegistry reg) => AppActions(
        registry: reg,
        places: PlacesDeps(
          save: ({required name, required lat, required lon, label}) async {
            final p = SavedPlaceRecord(key: 'k${saved.length + 1}', name: name, lat: lat, lon: lon, label: label);
            saved.add(p);
            return p;
          },
          list: () async => List.of(saved),
        ),
        watch: WatchDeps(
          choices: () async => [
            const WatchPlace(id: 'here', kind: PlaceKind.here, name: 'Where I am', subtitle: ''),
            for (final s in saved) WatchPlace(id: 'place:${s.key}', kind: PlaceKind.saved, name: s.name, subtitle: '', lat: s.lat, lon: s.lon, key: s.key),
          ],
          watched: () => watched,
          setWatched: (id, on) => on ? watched.add(id) : watched.remove(id),
        ),
        sources: SourceDeps(
          available: (_) => available,
          needsKey: (_) => missingKey,
          setOn: (r, on) async => on ? rowsOn.add(r.title) : rowsOn.remove(r.title),
        ),
        navigation: NavigationDeps(
          route: (id) async => id == 'r1' ? MapRoute.fromJson(fakeRouteJson(id: 'r1')) : throw StateError('evicted'),
          guiding: () => guiding,
          preview: (r) {
            calls.add('preview ${r.routeId}');
            return previewOk;
          },
          start: () async => calls.add('start'),
          show: () => calls.add('show'),
        ),
      );
}

void main() {
  late ActionRegistry reg;
  late Fakes f;

  setUp(() async {
    reg = ActionRegistry();
    f = Fakes();
    await f.actions(reg).publishAll();
  });

  test('every app action is installed, in module order', () {
    expect(reg.rejected, isEmpty);
    expect([for (final d in reg.definitions) d['id']],
        ['places.save', 'places.list', 'weather.watch_add', 'weather.watch_remove', 'home.source_switch', 'navigation.start']);
    expect(reg.definition('places.save')!.json['effect'], 'change');
    expect(reg.definition('places.list')!.json['effect'], 'read');
    expect(reg.definition('navigation.start')!.json['effect'], 'open');
    expect((reg.definition('weather.watch_add')!.json['fields'] as Map)['place']['enum'], ['Where I am', 'Home']);
    expect((reg.definition('home.source_switch')!.json['fields'] as Map)['source']['enum'], [for (final r in kCurated) sourceValue(r)]);
  });

  test('places.save saves the resolved place and the watch list learns it', () async {
    final r = await reg.run('places.save', {'name': 'Elk camp', 'place': {'lat': 44.21, 'lon': -114.93, 'label': 'Near Stanley'}, 'note': ''}, confirmId: 'c1');
    expect(r['status'], 'done');
    expect(r['result'], {'name': 'Elk camp', 'lat': 44.21, 'lon': -114.93, 'label': 'Near Stanley'});
    expect(f.saved.last.name, 'Elk camp');
    expect((reg.definition('weather.watch_add')!.json['fields'] as Map)['place']['enum'], ['Where I am', 'Home', 'Elk camp']);
    await reg.run('places.save', {'name': 'Spring', 'place': {'lat': 44.0, 'lon': -115.0}, 'note': 'Good water'});
    expect(f.saved.last.label, 'Good water');
  });

  test('places.list returns the saved places', () async {
    final r = await reg.run('places.list', {});
    expect(r['result'], {
      'places': [
        {'name': 'Home', 'lat': 43.6, 'lon': -116.2, 'label': 'Boise'},
      ],
    });
  });

  test('watch add and remove change the Places list', () async {
    expect((await reg.run('weather.watch_add', {'place': 'Home'}))['result'], {'place': 'Home', 'watched': true});
    expect(f.watched, {'here', 'place:k1'});
    await reg.run('weather.watch_remove', {'place': 'Where I am'});
    expect(f.watched, {'place:k1'});
    f.saved.clear();
    expect((await reg.run('weather.watch_add', {'place': 'Home'}))['error']['type'], 'not_found');
  });

  test('home.source_switch switches the row, or says why not', () async {
    expect((await reg.run('home.source_switch', {'source': 'wildfires', 'on': true}))['result'], {'source': 'Wildfires', 'on': true});
    expect(f.rowsOn, {'Wildfires'});
    await reg.run('home.source_switch', {'source': 'wildfires', 'on': false});
    expect(f.rowsOn, isEmpty);
    f.missingKey = true;
    expect((await reg.run('home.source_switch', {'source': 'satellite_fire_hotspots', 'on': true}))['error']['type'], 'needs_key');
    f.available = false;
    expect((await reg.run('home.source_switch', {'source': 'weather_alerts', 'on': true}))['error']['type'], 'not_set_up');
  });

  test('navigation.start previews the planned route, opens Maps and starts guidance', () async {
    final r = await reg.run('navigation.start', {'route_id': 'r1'});
    expect(r['result'], {'opened': 'Guidance to Cassia Regional Hospital'});
    expect(f.calls, ['preview r1', 'show', 'start']);
  });

  test('navigation.start fails when guiding or the route is gone', () async {
    f.guiding = true;
    expect((await reg.run('navigation.start', {'route_id': 'r1'}))['error']['type'], 'busy');
    f.guiding = false;
    expect((await reg.run('navigation.start', {'route_id': 'old'}))['error']['type'], 'not_found');
    f.previewOk = false;
    expect((await reg.run('navigation.start', {'route_id': 'r1'}))['error']['type'], 'not_found');
    expect(f.calls, ['preview r1']);
  });
}
