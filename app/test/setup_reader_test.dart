import 'package:cache/actions/setup_reader.dart';
import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// app.setup_status's value for a region (wording agreed with cache-llm-training, 2026-10-31).
void main() {
  Map<String, dynamic> ready(int bytes) => {'state': 'ready', 'tiles': 4, 'bytes': bytes, 'done_tiles': 4, 'done_bytes': bytes};

  final map = DownloadedArea(
      id: 'a', layerId: 'basemap', bounds: const GeoBounds(west: -117, south: 42, east: -111, north: 49), label: 'Idaho', minZoom: 0, maxZoom: 15,
      totalTiles: 10, doneTiles: 10, bytes: 1000, phase: AreaPhase.done);

  test('the agreed examples', () {
    final notFinished = LocalRegion(id: 'us-id', name: 'Idaho', areas: [map], routing: ready(100), places: {'state': 'downloading', 'tiles': 4, 'bytes': 20, 'done_tiles': 1, 'done_bytes': 5});
    expect(regionSetupValue(notFinished, age: '3 weeks old'), 'maps, routing; places not finished; 3 weeks old');
    final notPublished = LocalRegion(id: 'us-id', name: 'Idaho', areas: [map], routing: ready(100), places: {'state': 'failed', 'error': 'HTTP 404 from https://data.cached.info/places/current.json'});
    expect(regionSetupValue(notPublished), 'maps, routing; places not available yet');
    final whole = LocalRegion(id: 'us-id', name: 'Idaho', areas: [map], routing: ready(100), places: ready(20));
    expect(regionSetupValue(whole, age: '3 weeks old'), 'maps, routing, places; 3 weeks old');
  });

  test('a region with every part ready: the parts, then the age', () {
    final r = LocalRegion(id: 'us-id', name: 'Idaho', routing: ready(100), places: ready(20));
    expect(regionSetupValue(r, age: '3 weeks old'), 'routing, places; 3 weeks old');
  });

  test('a partly downloaded region: what is ready, then what is not, then the age', () {
    final r = LocalRegion(id: 'us-id', name: 'Idaho', routing: ready(100), places: {'state': 'downloading', 'tiles': 4, 'bytes': 20, 'done_tiles': 1, 'done_bytes': 5});
    expect(regionSetupValue(r, age: '3 weeks old'), 'routing; places not finished; 3 weeks old');
  });

  test('places not published for the area: not available yet', () {
    final r = LocalRegion(id: 'us-id', name: 'Idaho', routing: ready(100), places: {'state': 'failed', 'error': 'HTTP 404 from https://data.cached.info/places/current.json'});
    expect(regionSetupValue(r), 'routing; places not available yet');
  });

  test('nothing ready yet is said, never none installed', () {
    final r = LocalRegion(id: 'us-id', name: 'Idaho', routing: {'state': 'downloading', 'tiles': 4, 'bytes': 100, 'done_tiles': 0, 'done_bytes': 0}, wantsPlaces: true);
    expect(regionSetupValue(r, age: '1 day old'), 'nothing ready yet');
  });

  test('routing with no tile over the area: what the assistant reads has not changed', () {
    // The Regions screens say "not available yet" for it now (it read "Ready" with no road data). This text is a tool result:
    // it stays as it was until that change is approved on its own.
    const none = {'state': 'ready', 'tiles': 0, 'bytes': 0, 'done_tiles': 0, 'done_bytes': 0};
    final r = LocalRegion(id: 'drawn-1', name: 'Drawn area', areas: [map], routing: none, places: ready(20));
    expect(r.parts.firstWhere((p) => p.kind == RegionPartKind.directions).state, PartState.notAvailable, reason: 'what the screens read');
    expect(regionSetupValue(r, age: '3 weeks old'), 'maps, routing, places; 3 weeks old');
    expect(regionSetupValue(LocalRegion(id: 'drawn-2', name: 'Drawn area', routing: none)), 'routing');
  });

  test('a failed part reads as not finished', () {
    final r = LocalRegion(id: 'us-id', name: 'Idaho', routing: ready(100), places: {'state': 'failed', 'error': 'HTTP 503 from https://data.cached.info/places/b1/x.sqlite.gz'});
    expect(regionSetupValue(r), 'routing; places not finished');
  });
}
