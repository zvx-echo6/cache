import 'dart:io';

import 'package:cache/regions/region_catalogue.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/regions_fake.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('regions-cat'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('the index lists the countries by name with their shards', () async {
    final web = regionWeb();
    final c = RegionCatalogue(dir: () async => dir, fetch: web.fetch);
    final ix = await c.index();
    expect([for (final x in ix.countries) x.record.id], ['af', 'ca', 'us']);
    final us = ix.countries.last;
    expect(us.shard, 'us');
    expect(us.record.name, 'United States');
    expect(us.count, greaterThan(1000));
    expect(ix.polygonBase, 'https://cache.echo6.co/regions/polygons/');
    expect(ix.searchFiles['us'], 'us.search.json');
  });

  test('a shard holds the records and a tree where one region sits under several parents', () async {
    final c = RegionCatalogue(dir: () async => dir, fetch: regionWeb().fetch);
    final s = await c.shard('us');
    final idaho = s['us-id']!;
    expect(idaho.name, 'Idaho');
    expect(idaho.kind, 'region');
    expect(idaho.country, 'US');
    expect(idaho.parents, containsAll(['us', 'us-pacific-northwest', 'us-intermountain-west']));
    expect(idaho.bounds!.west, closeTo(-117.24, 0.01));
    expect(s['us-id-southern-idaho']!.kind, 'sub_state');
    expect(s['us-intermountain-west']!.kind, 'multi_state');

    final root = s.tree.single;
    expect(root.id, 'us');
    final top = {for (final n in root.children) n.id};
    expect(top, containsAll(['us-mountain-west', 'us-pacific-northwest']));
    var found = 0;
    void walk(RegionNode n) {
      if (n.id == 'us-id') found++;
      n.children.forEach(walk);
    }
    walk(root);
    expect(found, 2, reason: 'Idaho is in the Pacific Northwest and in the Intermountain West');

    // The United States crosses the antimeridian (the Aleutians): its box is cut to the larger side.
    final b = s['us']!.bounds!;
    expect(b.west, -180);
    expect(b.east, closeTo(-66.95, 0.01));
  });

  test('read once, the catalogue works offline; a month later it is fetched again', () async {
    final web = regionWeb();
    var now = DateTime.now();
    final c = RegionCatalogue(dir: () async => dir, fetch: web.fetch, now: () => now);
    await c.index();
    final rec = (await c.shard('us'))['us-id-twin-falls-county']!;
    final g = await c.geometry(rec);
    expect(g['type'], 'Polygon');
    expect(File('${dir.path}/polygons/us-id-twin-falls-county.geojson').existsSync(), isTrue);

    web.offline = true;
    final again = RegionCatalogue(dir: () async => dir, fetch: web.fetch, now: () => now);
    expect((await again.index()).countries, hasLength(3));
    expect((await again.shard('us'))['us-id'], isNotNull);
    expect((await again.geometry(rec))['type'], 'Polygon');

    web.offline = false;
    web.requested.clear();
    now = now.add(const Duration(days: 31));
    final later = RegionCatalogue(dir: () async => dir, fetch: web.fetch, now: () => now);
    await later.index();
    expect(web.requested.map((u) => u.path), contains('/regions/index.json'));

    // Stale and offline: the old copy is used.
    web.offline = true;
    final stale = RegionCatalogue(dir: () async => dir, fetch: web.fetch, now: () => now.add(const Duration(days: 90)));
    expect((await stale.index()).countries, hasLength(3));
  });

  test('never read and offline: it says so', () async {
    final web = regionWeb()..offline = true;
    final c = RegionCatalogue(dir: () async => dir, fetch: web.fetch);
    await expectLater(c.index(), throwsA(isA<Exception>()));
  });

  test('search finds regions by the start of their words, exact names first, larger places first', () async {
    final c = RegionCatalogue(dir: () async => dir, fetch: regionWeb().fetch);
    final rows = [...await c.globalSearch(), ...await c.shardSearch('us')];
    final idaho = searchRegions('idaho', rows);
    expect(idaho.first.id, 'us-id');
    expect(idaho.map((h) => h.id), contains('us-co-idaho-springs'));
    expect(idaho.where((h) => h.id == 'us-id'), hasLength(1), reason: 'a region in two lists shows once');

    final tf = searchRegions('twin falls', rows);
    expect(tf.first.name, 'Twin Falls');
    expect(tf.map((h) => h.id), contains('us-id-twin-falls-county'));
    expect(tf.firstWhere((h) => h.id == 'us-id-twin-falls').inside, isNotEmpty);

    expect(searchRegions('magic', rows).single.id, 'us-id-magic-valley');
    expect(searchRegions('southern ida', rows).first.id, 'us-id-southern-idaho');
    expect(searchRegions('  ', rows), isEmpty);
    expect(searchRegions('nowhere at all', rows), isEmpty);
    expect(tf.first.shardId, 'us');
  });

  test('the smallest region holding a point, for a later "Download <region>?"', () async {
    final c = RegionCatalogue(dir: () async => dir, fetch: regionWeb().fetch);
    await c.shard('us');
    expect(c.regionAt(42.2, -114.6)?.id, 'us-id-twin-falls-county');
    expect(c.regionAt(44.0, -114.0, kinds: const {'region'})?.id, 'us-id');
    expect(c.regionAt(10, 10), isNull);
  });

  test('kinds have plain names', () {
    expect(regionKindLabel('region', country: 'US'), 'State');
    expect(regionKindLabel('region', country: 'CA'), 'Region');
    expect(regionKindLabel('multi_state'), 'Several states');
    expect(regionKindLabel('sub_state'), 'Part of a state');
    expect(regionKindLabel('locality'), 'City or town');
    expect(regionKindHeading('county'), 'Counties');
  });
}
