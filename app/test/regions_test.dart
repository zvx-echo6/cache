import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/ui/format.dart';
import 'package:cache/maps/ui/layer_sheet.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/ui/search_panel.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/regions/problem_words.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/ui/region_actions.dart';
import 'package:cache/regions/ui/region_download.dart';
import 'package:cache/regions/ui/region_page.dart';
import 'package:cache/regions/ui/regions_list_sheet.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/regions/ui/regions_screen.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/screens/settings/deps.dart';
import 'package:cache/screens/settings/maps_page.dart';
import 'package:cache/search/core_config.dart';
import 'package:cache/weather/catalogue_store.dart' show NetworkProblem;
import 'package:cache/settings/data_policy.dart';
import 'package:cache/settings/hub.dart';
import 'package:cache/settings/space.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show MapLibreMap, MapLibrePlatform;

import 'location_service_test.dart' show FakeSource;
import 'nav_fakes.dart';
import 'navigation_camera_test.dart' show NoSurface;
import 'support/regions_fake.dart';
import 'support/settings_rig.dart';

const _county = 'us-id-twin-falls-county';

/// The settings rig plus the regions part on fakes: the trimmed catalogue fixtures, the fake region engine and the test layer
/// engine. The catalogue is read once up front (it reads files, which a widget test does only inside runAsync).
class _Rig {
  late SettingsRig s;
  late FakeRegions core;
  late RegionCatalogue catalogue;
  late RegionsState regions;
  late RegionShard us;
  Map<String, Object?>? config;

  RegionRecord get county => us[_county]!;

  static Future<_Rig> boot(
    WidgetTester tester, {
    ConnectionKind connection = ConnectionKind.wifi,
    bool places = false,
    bool placesBuildOnlyWithRegion = false,
    Future<void> Function()? onPlacesChanged,
    bool Function()? synced,
    Future<List<int>> Function(Uri u, Future<List<int>> Function(Uri u) inner)? wrapFetch,
  }) async {
    final r = _Rig();
    r.s = await SettingsRig.create(tester, connection: connection);
    r.core = FakeRegions(tileDir: '${r.s.dir.path}/regions/tiles/2026-10')
      ..placesEnabled = places
      ..placesBuildOnlyWithRegion = placesBuildOnlyWithRegion;
    Directory(r.core.tileDir).createSync(recursive: true);
    final web = regionWeb();
    r.catalogue = RegionCatalogue(dir: () async => Directory('${r.s.dir.path}/region-catalogue'), fetch: wrapFetch == null ? web.fetch : (u) => wrapFetch(u, web.fetch));
    r.regions = RegionsState(
      policy: r.s.policy,
      supportDir: () async => r.s.dir,
      catalogue: r.catalogue,
      maps: r.s.maps,
      opener: (config) async {
        r.config = config;
        return r.core;
      },
      onPlacesChanged: onPlacesChanged,
      syncedWithOtherDevice: synced,
    );
    await tester.runAsync(() async {
      await r.regions.init();
      await r.catalogue.index();
      r.us = await r.catalogue.shard('us');
      await r.catalogue.globalSearch();
      await r.catalogue.shardSearch('us');
      for (final id in ['us-id', 'us-ut', _county]) {
        await r.catalogue.geometry(r.us[id]!);
      }
    });
    return r;
  }

  /// [settle] until [done] holds (at most [turns] turns). A widget test lets the app's real file work run only inside runAsync,
  /// and what follows each step only at the next pump, so every file step (open, write, flush, close, rename) takes one turn: a
  /// chain like removing a region (two saves of regions-app.json around a refresh) needs about a dozen turns, more when the
  /// machine is busy and a step misses its turn. A fixed number of turns ran out on a busy CI runner now and then.
  /// Every wait in these tests is one of these: on what the next check reads, never a fixed time (a fixed wait ran out under
  /// load on the build boxes).
  /// Then the test's own clock goes on [after] (sheets and pop-ups finish opening, short timers run out): that time is the
  /// test's, not the machine's, so it is the same under any load.
  Future<void> settleUntil(WidgetTester tester, bool Function() done, {int turns = 300, Duration after = const Duration(milliseconds: 600)}) async {
    for (var i = 0; i < turns && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    for (var t = Duration.zero; t < after; t += const Duration(milliseconds: 50)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Reads the core's status again until [done] holds: what a download started (its saves of the regions file) may still be
  /// finishing when the fake core says a part is done.
  Future<void> refreshUntil(WidgetTester tester, bool Function() done, {int turns = 300}) async {
    for (var i = 0; i < turns; i++) {
      await tester.runAsync(regions.refresh);
      await tester.pump();
      if (done()) return;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    await s.dispose(tester);
  }
}

bool _shown(Finder f) => f.evaluate().isNotEmpty;

Future<void> _openCountySheet(WidgetTester tester) async {
  await tester.enterText(find.byKey(const ValueKey('region-search')), 'twin falls county');
  await tester.pump();
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('hit-$_county')));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {

  // Maps sync with one writer per file (regions_share.dart): each device lists its own regions and the ones linked devices share, and a
  // delete is shared and ends the region on every device that has it; a region added after the delete stays.
  group('regions shared with linked devices', () {
    void peerFile(_Rig r, String device, Map<String, Object?> regions) {
      final d = Directory('${r.s.dir.path}/regions/regions-share')..createSync(recursive: true);
      File('${d.path}/$device.json').writeAsStringSync(jsonEncode({'v': 1, 'regions': regions}));
    }

    void peerDeletes(_Rig r, String device, List<(String, int)> deletes) {
      final d = Directory('${r.s.dir.path}/regions/regions-share')..createSync(recursive: true);
      File('${d.path}/$device.deletes.json').writeAsStringSync(jsonEncode({'deletes': [for (final x in deletes) {'id': x.$1, 'at': x.$2}]}));
    }

    Map<String, dynamic> readJson(String path) => jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

    Future<_Rig> bootShared(WidgetTester tester) async {
      // the region engine names this device when it opens (cache_places::share::share_id); the fake core does not
      final r = await _Rig.boot(tester);
      File('${r.s.dir.path}/regions/.share-id')
        ..createSync(recursive: true)
        ..writeAsStringSync('phone1');
      return r;
    }

    testWidgets('a region only a linked device shares is listed, this device shares its own, and the union is read-only', (tester) async {
      final r = await bootShared(tester);
      await tester.runAsync(() => r.regions.download(r.county, routing: true, map: false));
      r.core.finish(_county);
      await r.refreshUntil(tester, () => r.regions.regionOf(_county)?.phase == RegionPhase.ready);
      peerFile(r, 'peerdev', {
        'us-ut': {'name': 'Utah', 'added': 1000, 'routing': true, 'places': false, 'routingPart': {'state': 'ready', 'bytes': 1234}, 'kind': null},
        // the same region both hold: this device's own is the one listed
        _county: {'name': 'Twin Falls (other device)', 'added': 5, 'routing': true, 'routingPart': {'state': 'ready', 'bytes': 9}},
      });
      await tester.runAsync(r.regions.refresh);
      expect({for (final l in r.regions.local) l.id}, {_county, 'us-ut'});
      expect(r.regions.regionOf('us-ut')!.name, 'Utah');
      expect(r.regions.regionOf('us-ut')!.routingState, 'ready');
      expect(r.regions.regionOf('us-ut')!.routingBytes, 1234);
      expect(r.regions.regionOf('us-ut')!.phase, RegionPhase.ready, reason: 'as the other device says it stands');
      expect(r.regions.regionOf('us-ut')!.parts.map((p) => p.kind), [RegionPartKind.directions]);
      expect(r.regions.regionOf(_county)!.name, 'Twin Falls County', reason: 'own first');
      // nothing of the other device's was added to this device's own engine
      expect(r.core.regions.keys, [_county]);
      // this device shares its own, under its own name, and not the other device's
      final mine = readJson('${r.s.dir.path}/regions/regions-share/phone1.json');
      expect((mine['regions'] as Map).keys, [_county]);
      expect((((mine['regions'] as Map)[_county] as Map)['routingPart'] as Map)['state'], 'ready');
      expect(((mine['regions'] as Map)[_county] as Map)['name'], 'Twin Falls County');
      await r.dispose(tester);
    });

    testWidgets('deleting a region shared by another device deletes it everywhere: a record in this device\'s folder, and a later download stays', (tester) async {
      final r = await bootShared(tester);
      peerFile(r, 'peerdev', {'us-ut': {'name': 'Utah', 'added': 1000, 'routing': true, 'routingPart': {'state': 'ready'}}});
      await tester.runAsync(r.regions.refresh);
      expect(r.regions.regionOf('us-ut'), isNotNull);
      await tester.runAsync(() => r.regions.remove('us-ut'));
      final deletes = (readJson('${r.s.dir.path}/regions/regions-share/phone1.deletes.json')['deletes'] as List).cast<Map>();
      expect(deletes.single['id'], 'us-ut');
      expect(r.regions.regionOf('us-ut'), isNull, reason: 'gone at once, though the other device still lists it');
      await tester.runAsync(r.regions.refresh);
      expect(r.regions.regionOf('us-ut'), isNull, reason: 'and stays gone while its file still lists it');
      // the other device downloads it again: newer than the delete, it shows
      final at = (deletes.single['at'] as num).toInt();
      peerFile(r, 'peerdev', {'us-ut': {'name': 'Utah', 'added': at + 60000, 'routing': true, 'routingPart': {'state': 'ready'}}});
      await tester.runAsync(r.regions.refresh);
      expect(r.regions.regionOf('us-ut'), isNotNull);
      await r.dispose(tester);
    });

    testWidgets('a delete another device shared ends this device\'s own copy of the region, and writes no delete of its own', (tester) async {
      final r = await bootShared(tester);
      await tester.runAsync(() => r.regions.download(r.county, routing: true, map: true));
      r.core.finish(_county);
      r.s.engine.finishAll();
      await r.refreshUntil(tester, () => r.regions.regionOf(_county)?.phase == RegionPhase.ready);
      expect(r.s.engine.storageTotal, greaterThan(0));
      final when = DateTime.now().millisecondsSinceEpoch + 1000;
      peerDeletes(r, 'peerdev', [(_county, when)]);
      await r.refreshUntil(tester, () => r.regions.regionOf(_county) == null);
      expect(r.regions.regionOf(_county), isNull);
      expect(r.core.regions, isEmpty);
      expect(r.core.calls, contains('remove'));
      expect(r.s.engine.storageTotal, 0, reason: 'its map area went too');
      expect(File('${r.s.dir.path}/regions/regions-share/phone1.deletes.json').existsSync(), isFalse, reason: 'the delete is the other device\'s, with its own time');
      // downloaded again after that delete: it stays, and the old record does not end it
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1200)));
      await tester.runAsync(() => r.regions.download(r.county, routing: true, map: false));
      r.core.finish(_county);
      await r.refreshUntil(tester, () => r.regions.regionOf(_county)?.phase == RegionPhase.ready);
      await tester.runAsync(r.regions.refresh);
      expect(r.regions.regionOf(_county), isNotNull);
      await r.dispose(tester);
    });


    testWidgets('a refresh that finishes after the state was disposed (a screen left mid-refresh) ends quietly: no notify after dispose', (tester) async {
      final r = await _Rig.boot(tester);
      final again = RegionsState(policy: r.s.policy, supportDir: () async => r.s.dir, catalogue: r.catalogue, maps: r.s.maps, opener: (_) async => r.core);
      await tester.runAsync(() async {
        await again.init();
        final pending = again.refresh();
        again.dispose();
        await pending;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(tester.takeException(), isNull);
      await r.dispose(tester);
    });

    // ---- the outline back-fill (A2): outlines only, a marker per region, never in the quiet hours, the mobile data rule ----------------
    Future<List<int>> squares(Uri u, Future<List<int>> Function(Uri) inner, List<String> asked) async {
      if (u.path.endsWith('.geojson')) {
        asked.add(u.pathSegments.last);
        return Uint8List.fromList(utf8.encode(jsonEncode({'type': 'Polygon', 'coordinates': [[[-115.0, 42.0], [-114.0, 42.0], [-114.0, 43.0], [-115.0, 43.0], [-115.0, 42.0]]]})));
      }
      return inner(u);
    }

    Future<_Rig> keptWithOutlines(WidgetTester tester, List<String> asked, {ConnectionKind connection = ConnectionKind.wifi}) async {
      final r = await _Rig.boot(tester, connection: connection, wrapFetch: (u, inner) => squares(u, inner, asked));
      r.s.settings.setMobileForDownloads(true); // so the download itself may run on mobile data; the tests set it as they need after
      await tester.runAsync(() => r.regions.download(r.county, routing: true, map: false));
      await tester.runAsync(() async {
        for (var i = 0; i < 200 && !await r.catalogue.outlinesDone(r.county.id); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      return r;
    }

    Directory polygons(_Rig r) => Directory('${r.s.dir.path}/region-catalogue/polygons');
    void forget(_Rig r) {
      for (final f in polygons(r).listSync().whereType<File>()) {
        f.deleteSync();
      }
    }

    RegionsState again(_Rig r, DateTime Function() clock) => RegionsState(
          policy: r.s.policy,
          supportDir: () async => r.s.dir,
          catalogue: r.catalogue,
          maps: r.s.maps,
          opener: (_) async => r.core,
          clock: clock,
        );

    testWidgets('the region search offers towns of the country the person has regions in, with no shard opened and no position (a browser)', (tester) async {
      final r = await _Rig.boot(tester);
      await tester.runAsync(() => r.regions.download(r.county, routing: true, map: false));
      // A new session: the catalogue has read nothing but the global list, and there is no position.
      final fresh = RegionCatalogue(dir: () async => Directory('${r.s.dir.path}/region-catalogue'), fetch: regionWeb().fetch);
      final state = RegionsState(policy: r.s.policy, supportDir: () async => r.s.dir, catalogue: fresh, maps: r.s.maps, opener: (_) async => r.core);
      await tester.runAsync(() => state.init());
      expect(fresh.loadedShards, isEmpty);
      final rows = await tester.runAsync(() => state.searchRows());
      final names = {for (final h in rows!) if (h.kind == 'locality') h.name};
      expect(names, contains('Twin Falls'), reason: 'a town the global list does not hold, found from the country list of a kept region');
      state.dispose();
      await r.dispose(tester);
    });

    testWidgets('outline back-fill: a region that has its tiles and no outlines gets them all and a marker; a second run fetches nothing', (tester) async {
      final asked = <String>[];
      final r = await keptWithOutlines(tester, asked);
      expect(await tester.runAsync(() => r.catalogue.outlinesDone(r.county.id)), isTrue, reason: 'the download left its marker');
      forget(r);
      asked.clear();
      await tester.runAsync(() => r.regions.backfillOutlines());
      expect(asked, isNotEmpty, reason: 'an empty folder: every outline is fetched');
      expect(await tester.runAsync(() => r.catalogue.outlinesDone(r.county.id)), isTrue);
      final first = asked.length;
      await tester.runAsync(() => r.regions.backfillOutlines());
      expect(asked.length, first, reason: 'the marker is there: nothing is fetched again');
      await r.dispose(tester);
    });

    testWidgets('outline back-fill: a partly filled folder fetches only the missing outlines', (tester) async {
      final asked = <String>[];
      final r = await keptWithOutlines(tester, asked);
      final want = {for (final x in r.catalogue.areaRecordsOf(r.county)) '${x.id}.geojson'};
      final files = polygons(r).listSync().whereType<File>().where((f) => want.contains(f.uri.pathSegments.last)).toList();
      expect(files.length, greaterThan(1));
      final gone = files.first.uri.pathSegments.last;
      files.first.deleteSync();
      File('${polygons(r).path}/.done-${r.county.id}').deleteSync();
      asked.clear();
      await tester.runAsync(() => r.regions.backfillOutlines());
      expect(asked, [gone], reason: 'only the one that was missing');
      await r.dispose(tester);
    });

    testWidgets('outline back-fill: a failure leaves no marker and the next run tries again', (tester) async {
      final asked = <String>[];
      var fail = false;
      final r = await _Rig.boot(tester, wrapFetch: (u, inner) async {
        if (u.path.endsWith('.geojson') && fail) throw const NetworkProblem('no connection');
        return squares(u, inner, asked);
      });
      await tester.runAsync(() => r.regions.download(r.county, routing: true, map: false));
      await tester.runAsync(() async {
        for (var i = 0; i < 200 && !await r.catalogue.outlinesDone(r.county.id); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      forget(r);
      fail = true;
      await tester.runAsync(() => r.regions.backfillOutlines());
      expect(await tester.runAsync(() => r.catalogue.outlinesDone(r.county.id)), isFalse, reason: 'a failed store leaves no marker');
      fail = false;
      asked.clear();
      await tester.runAsync(() => r.regions.backfillOutlines());
      expect(asked, isNotEmpty, reason: 'it tries again');
      expect(await tester.runAsync(() => r.catalogue.outlinesDone(r.county.id)), isTrue);
      await r.dispose(tester);
    });

    testWidgets('outline back-fill: updateRegion back-fills the outlines and asks neither the core nor the map to update when nothing else is out of date', (tester) async {
      final asked = <String>[];
      final r = await keptWithOutlines(tester, asked);
      forget(r);
      asked.clear();
      final before = List<String>.of(r.core.calls);
      await tester.runAsync(() => r.regions.updateRegion(r.county.id));
      expect(asked, isNotEmpty, reason: 'the outlines were fetched');
      expect(r.core.calls.where((c) => c.startsWith('update')).length, before.where((c) => c.startsWith('update')).length, reason: 'no routing or places update was asked of the core');
      await r.dispose(tester);
    });

    testWidgets('outline back-fill: it does nothing from 1 to 8 AM local, and runs at other hours', (tester) async {
      final asked = <String>[];
      final r = await keptWithOutlines(tester, asked);
      forget(r);
      asked.clear();
      final night = again(r, () => DateTime(2026, 11, 25, 3, 30));
      await tester.runAsync(() async {
        await night.init();
        await night.backfillOutlines();
      });
      expect(asked, isEmpty, reason: 'quiet hours');
      final morning = again(r, () => DateTime(2026, 11, 25, 8, 0));
      await tester.runAsync(() async {
        await morning.init();
        await morning.backfillOutlines();
      });
      expect(asked, isNotEmpty, reason: '8 AM is out of the quiet hours');
      night.dispose();
      morning.dispose();
      await r.dispose(tester);
    });

    testWidgets('outline back-fill: on mobile data it follows the setting for downloads (off: waits; on: runs)', (tester) async {
      final asked = <String>[];
      final r = await keptWithOutlines(tester, asked, connection: ConnectionKind.mobile);
      forget(r);
      asked.clear();
      r.s.settings.setMobileForDownloads(false);
      await tester.runAsync(() => r.regions.backfillOutlines());
      expect(asked, isEmpty, reason: 'mobile data is not allowed for downloads');
      r.s.settings.setMobileForDownloads(true);
      await tester.runAsync(() => r.regions.backfillOutlines());
      expect(asked, isNotEmpty, reason: 'mobile data is allowed for downloads');
      await r.dispose(tester);
    });

    testWidgets('a region an earlier version adopted from the other device\'s store file is listed once, with the other device\'s; one whose areas are gone is dropped', (tester) async {
      final r = await _Rig.boot(tester);
      File('${r.s.dir.path}/regions/.share-id')
        ..createSync(recursive: true)
        ..writeAsStringSync('phone1');
      File('${r.s.dir.path}/$kRegionsAppFile').writeAsStringSync(jsonEncode({
        'regions': {
          'area-monaco': {'name': 'Monaco', 'kind': 'area', 'areas': ['a-monaco'], 'routing': false, 'places': false},
          'area-gone': {'name': 'Gone', 'kind': 'area', 'areas': ['a-nothing'], 'routing': false, 'places': false},
        },
      }));
      peerFile(r, 'peerdev', {'monaco-id': {'name': 'Monaco', 'added': 1000, 'areas': ['a-monaco']}});
      final again = RegionsState(policy: r.s.policy, supportDir: () async => r.s.dir, catalogue: r.catalogue, maps: r.s.maps, opener: (_) async => r.core);
      await tester.runAsync(() async {
        await again.init();
        await again.refresh();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      expect({for (final l in again.local) l.id}, {'monaco-id'}, reason: 'Monaco once, the other device\'s; nothing left as 0 B');
      final saved = (jsonDecode(File('${r.s.dir.path}/$kRegionsAppFile').readAsStringSync()) as Map)['regions'] as Map;
      expect(saved, isEmpty, reason: 'both adopted entries were dropped from this device\'s list');
      again.dispose();
      await r.dispose(tester);
    });

    testWidgets('files that are not a device\'s share are never read', (tester) async {
      final r = await bootShared(tester);
      final d = Directory('${r.s.dir.path}/regions/regions-share')..createSync(recursive: true);
      File('${d.path}/phone1.json').writeAsStringSync(jsonEncode({'regions': {'own-echo': {'name': 'Echo'}}}));
      File('${d.path}/peerdev (conflict, X, 2026-11-15 2040 UTC).json').writeAsStringSync(jsonEncode({'regions': {'conflict-region': {'name': 'C'}}}));
      File('${d.path}/.peerdev.json.tmp1').writeAsStringSync('{"regions": {"half": {"name": "H"}}}');
      File('${d.path}/broken.json').writeAsStringSync('{not json');
      await tester.runAsync(r.regions.refresh);
      expect(r.regions.local, isEmpty);
      await r.dispose(tester);
    });
  });

  group('delete confirmation', () {
    Future<void> askDelete(WidgetTester tester, _Rig r) async {
      await tester.runAsync(() => r.regions.download(r.county, routing: true, map: false));
      r.core.finish(_county);
      await r.refreshUntil(tester, () => r.regions.regionOf(_county)?.phase == RegionPhase.ready);
      await r.s.show(tester, RegionsScreen(regions: r.regions, initialTab: 1));
      await tester.pump();
      await tester.longPress(find.byKey(const ValueKey('local-$_county')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('region-action-delete')));
      await tester.pumpAndSettle();
    }

    testWidgets('asks "Delete this region?" and, when Maps is synced with a linked device, says it deletes on every synced device', (tester) async {
      final r = await _Rig.boot(tester, synced: () => true);
      await askDelete(tester, r);
      expect(find.text('Delete this region?'), findsOneWidget);
      expect(find.text('Deleting this will delete this from all synced devices.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('delete-region-cancel')));
      await tester.pumpAndSettle();
      expect(r.regions.regionOf(_county), isNotNull, reason: 'Cancel deletes nothing');
      await r.dispose(tester);
    });

    testWidgets('without a synced device it asks only the question', (tester) async {
      final r = await _Rig.boot(tester, synced: () => false);
      await askDelete(tester, r);
      expect(find.text('Delete this region?'), findsOneWidget);
      expect(find.text('Deleting this will delete this from all synced devices.'), findsNothing);
      await r.dispose(tester);
    });
  });
  testWidgets('the tree browses regions at every scale, and a region shows under each region it is in', (tester) async {
    final r = await _Rig.boot(tester);
    await r.s.show(tester, RegionsScreen(regions: r.regions));
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);
    expect(find.text('Updates'), findsOneWidget);
    expect(find.text('United States'), findsOneWidget);

    await tester.tap(find.text('United States'));
    await tester.pumpAndSettle();
    expect(find.text('Download United States'), findsOneWidget);
    expect(find.text('SEVERAL STATES'), findsOneWidget);
    await tester.tap(find.text('Pacific Northwest'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Idaho'));
    await tester.pumpAndSettle();
    expect(find.text('Download Idaho'), findsOneWidget);
    expect(find.text('Southern Idaho'), findsOneWidget);
    expect(find.text('PARTS OF THE STATE'), findsOneWidget);
    expect(find.text('METRO AREAS'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('a region of the catalogue: one pop-up with its parts and its size from the catalogue, nothing worked out; Download starts them', (tester) async {
    final r = await _Rig.boot(tester);
    await r.s.show(tester, RegionsScreen(regions: r.regions));
    r.core.calls.clear();
    await _openCountySheet(tester);
    await r.settleUntil(tester, () => _shown(find.text('Download Twin Falls County?')));
    final offer = r.regions.offer(r.county);
    expect(offer.kind, RegionOfferKind.download);
    expect(find.text('Download Twin Falls County?'), findsOneWidget);
    // the core's plan says what it takes on the device and what is fetched (the catalogue's figure only offline)
    await r.settleUntil(tester, () => find.textContaining('Takes ', findRichText: true).evaluate().isNotEmpty);
    expect(find.textContaining('Takes ', findRichText: true), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing, reason: 'no per-part sheet');
    await tester.tap(find.byKey(const ValueKey('confirm-download')));
    await tester.pump();
    expect(find.text('Downloading Twin Falls County'), findsOneWidget, reason: 'the tap says what it did');
    await r.settleUntil(tester, () => r.core.added.isNotEmpty && r.s.engine.areasOf('basemap').isNotEmpty);
    expect(r.core.added.single['id'], _county);
    expect(r.core.added.single['geometry'], isA<Map<String, dynamic>>());
    expect(r.s.engine.areasOf('basemap').single.label, 'Twin Falls County');

    // A drawn area is the one region worked out on the phone; without a connection the core cannot plan it and says so.
    r.core.offline = true;
    final p = (await tester.runAsync(() => r.regions.plan(r.us['us-ut']!)))!;
    expect(p.routing, isNull);
    expect(p.routingProblem, 'Needs a connection to work out the size.');
    await r.dispose(tester);
  });

  testWidgets('a region downloads, shows its progress, is ready, points routing at the tile folder, and is removed', (tester) async {
    final r = await _Rig.boot(tester);
    // The map part runs until this test finishes it: by itself it finished 20 ms (real time) after it started, which on a busy
    // machine was before "Starting…" was checked.
    r.s.engine.autoFinish = false;
    await tester.runAsync(() => r.regions.download(r.county, routing: true, map: true));
    await r.s.show(tester, RegionsScreen(regions: r.regions, initialTab: 1));
    await tester.pump();
    expect(find.text('Twin Falls County'), findsOneWidget);
    // the download pattern: one line and one bar for the whole region, "Starting…" until its first bytes
    expect(find.byKey(const ValueKey('local-$_county-line')), findsOneWidget);
    expect(find.text('Starting…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // with no position known, everything downloads from the region's centre outwards
    final b = r.county.bounds!;
    final centre = [(b.south + b.north) / 2, (b.west + b.east) / 2];
    expect(r.core.added.single['near'], centre);
    expect(r.s.engine.nearOf['Twin Falls County'], (lat: centre[0], lon: centre[1]));

    r.core.finish(_county);
    r.s.engine.finishAll();
    await r.refreshUntil(tester, () => _shown(find.textContaining('On this device · ')));
    expect(find.textContaining('On this device · '), findsOneWidget);
    expect(find.textContaining('next time Cache opens'), findsNothing, reason: 'the next route uses it, nothing waits for a restart');

    final saved = jsonDecode(File('${r.s.dir.path}/$kRegionsAppFile').readAsStringSync()) as Map;
    expect((saved['routing'] as Map)['tile_dir'], r.core.tileDir);
    expect((saved['routing'] as Map)['regions'], ['Twin Falls County']);
    final files = Directory('${r.s.dir.path}/files')..createSync();
    // The core is always given the router and the region engine; it routes on the engine's folder, so nothing changes here.
    final extras = buildCoreExtras(filesDir: files, supportDir: r.s.dir);
    expect(((extras['routing'] as Map)['valhalla'] as Map)['tiles'], '');
    expect((extras['regions'] as Map)['dir'], '${r.s.dir.path}/regions');

    // press and hold: the region's menu; Delete asks first
    await tester.longPress(find.byKey(const ValueKey('local-$_county')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('region-action-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete this region?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('delete-region-confirm-button')));
    // Until the removal has saved, refreshed and told the screen (see settleUntil).
    await r.settleUntil(tester, () => r.regions.local.isEmpty && find.text('Nothing downloaded yet').evaluate().isNotEmpty);
    expect(r.core.regions, isEmpty);
    expect(r.core.calls, contains('remove'));
    expect(r.s.engine.storageTotal, 0, reason: 'its map area is deleted too');
    expect(find.text('Nothing downloaded yet'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('on mobile data with downloads off it asks first, then pauses and goes on when allowed', (tester) async {
    final r = await _Rig.boot(tester, connection: ConnectionKind.mobile);
    expect(r.core.policies.last, {'network': false, 'hold': false}, reason: 'the same rule as sharing: no mobile data unless downloads may use it');
    await r.s.show(tester, RegionsScreen(regions: r.regions));
    await _openCountySheet(tester);
    await r.settleUntil(tester, () => _shown(find.byKey(const ValueKey('download-mobile'))));
    // The pop-up says so and offers Wait for Wi-Fi first.
    expect(find.byKey(const ValueKey('download-mobile')), findsOneWidget);
    expect(r.core.added, isEmpty, reason: 'nothing starts before the person says so');
    await tester.tap(find.byKey(const ValueKey('download-now')));
    await r.settleUntil(tester, () => r.core.added.isNotEmpty && r.core.regions[_county]?['state'] == 'paused' && r.regions.regionOf(_county)?.phase == RegionPhase.paused);
    expect(r.core.added, hasLength(1));
    expect(r.core.regions[_county]!['state'], 'paused');

    await tester.tap(find.text('Local'));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for Wi-Fi'), findsWidgets);

    r.s.settings.setMobileForDownloads(true);
    await r.settleUntil(tester, () => r.core.policies.last['network'] == true);
    expect(r.core.policies.last, {'network': true, 'hold': false});
    await tester.runAsync(r.regions.refresh);
    await tester.pump();
    expect(r.core.regions[_county]!['state'], 'downloading');
    expect(find.textContaining('Waiting for Wi-Fi'), findsNothing);
    expect(find.byKey(const ValueKey('local-$_county-line')), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('a region downloads from where the phone is; each part says where it stands', (tester) async {
    final rig = await SettingsRig.create(tester);
    final s = RegionsState(
      policy: rig.policy,
      supportDir: () async => rig.dir,
      catalogue: RegionCatalogue(dir: () async => rig.dir),
      maps: rig.maps,
      position: () => (lat: 42.56, lon: -114.46),
    );
    const county = RegionRecord(id: 'c', name: 'C', kind: 'county', bbox: [-115.0, 42.0, -114.0, 43.0]);
    expect(s.nearFor(county), (lat: 42.56, lon: -114.46));
    final l = LocalRegion(
      id: 'c',
      name: 'C',
      routing: {'state': 'downloading', 'bytes': 100, 'done_bytes': 40},
      places: {'state': 'ready', 'bytes': 10, 'done_bytes': 10},
      areas: [DownloadedArea(id: 'a', layerId: 'basemap', bounds: const GeoBounds(south: 42, west: -115, north: 43, east: -114), label: 'C', minZoom: 0, maxZoom: 14, totalTiles: 10, doneTiles: 10, phase: AreaPhase.done)],
      offroad: const [OffroadPackState(name: 'Idaho', bytes: 1000, doneBytes: 0, done: false)],
    );
    // the parts that are ready are not named: they work already
    expect(l.partsLine, 'Directions 40% · Off-road waiting');
    expect([for (final p in l.parts) '${p.name} ${p.words}'], ['Map ready', 'Directions 40%', 'Places ready', 'Off-road waiting']);
    s.dispose();
    await rig.dispose(tester);
  });

  testWidgets('Local lists what is on the phone, largest first', (tester) async {
    final r = await _Rig.boot(tester);
    r.core.sizes
      ..['us-id'] = 900 << 20
      ..['us-ut'] = 500 << 20
      ..[_county] = 120 << 20;
    await tester.runAsync(() async {
      for (final id in [_county, 'us-id', 'us-ut']) {
        await r.regions.download(r.us[id]!, routing: true, map: false);
        r.core.finish(id);
      }
      await r.regions.refresh();
    });
    await r.s.show(tester, RegionsScreen(regions: r.regions, initialTab: 1));
    await tester.pump();
    expect([for (final l in r.regions.local) l.id], ['us-id', 'us-ut', _county]);
    final y = [for (final id in ['us-id', 'us-ut', _county]) tester.getTopLeft(find.byKey(ValueKey('local-$id'))).dy];
    expect(y[0] < y[1] && y[1] < y[2], isTrue);
    expect(find.text('On this device · 900 MB'), findsOneWidget);
    expect(find.text('Tap a region to open it. Press and hold for Carry on, Check for update and Delete.'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('Updates groups road routing and maps, and Update all updates both', (tester) async {
    final r = await _Rig.boot(tester);
    await tester.runAsync(() => r.regions.download(r.county, routing: true, map: true));
    r.core.finish(_county);
    await r.refreshUntil(tester, () => r.regions.regionOf(_county)?.phase == RegionPhase.ready);
    await r.s.show(tester, RegionsScreen(regions: r.regions, initialTab: 2));
    await tester.pump();
    expect(find.text('ROAD ROUTING'), findsOneWidget);
    expect(find.text('MAP'), findsOneWidget);
    expect(find.text('Up to date'), findsOneWidget);
    expect(find.byKey(const ValueKey('map-$_county')), findsOneWidget);

    r.core.update = {'build': '2026-11', 'download_bytes': 5 << 20};
    await tester.tap(find.text('Check for updates'));
    await r.settleUntil(tester, () => r.core.calls.contains('check_update') && _shown(find.text('New road routing')));
    expect(r.core.calls, contains('check_update'));
    expect(find.text('New road routing'), findsOneWidget);
    expect(find.text('2026-11 · About 5.0 MB to download'), findsOneWidget);

    // below the fold on the test's screen: scrolled to, as on a phone
    await tester.ensureVisible(find.byKey(const ValueKey('update-all')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('update-all')));
    await r.settleUntil(tester, () => r.core.build == '2026-11' && _shown(find.text('Up to date')) && r.s.engine.areasOf('basemap').single.phase.name == 'done');
    expect(r.core.calls, contains('update'));
    expect(r.core.build, '2026-11');
    expect(find.text('Up to date'), findsOneWidget);
    expect(r.s.engine.areasOf('basemap').single.phase.name, 'done', reason: 'the map was fetched again');
    await r.dispose(tester);
  });

  // Link audit: a region's row under Updates > Map opens the region's page.
  testWidgets('a region under Updates > Map opens its page', (tester) async {
    final r = await _Rig.boot(tester);
    await tester.runAsync(() => r.regions.download(r.county, routing: true, map: true));
    r.core.finish(_county);
    await r.refreshUntil(tester, () => r.regions.regionOf(_county)?.phase == RegionPhase.ready);
    await r.s.show(tester, RegionsScreen(regions: r.regions, initialTab: 2));
    await tester.pump();
    expect(find.byType(RegionPage), findsNothing);
    await tester.tap(find.byKey(const ValueKey('map-$_county')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(RegionPage), findsOneWidget);
    expect(find.text(r.county.name), findsWidgets);
    await r.dispose(tester);
  });

  // Link audit, batch 2: a downloaded region shows on the map, from its page and from its hold menu.
  testWidgets('a region on the phone: Show on map on its page and in its hold menu asks for the map fitted to the region', (tester) async {
    final r = await _Rig.boot(tester);
    await tester.runAsync(() => r.regions.download(r.county, routing: true, map: true));
    r.core.finish(_county);
    await r.refreshUntil(tester, () => r.regions.regionOf(_county)?.phase == RegionPhase.ready);
    final box = r.regions.boundsOf(_county);
    expect(box, isNotNull);
    expect(box, r.county.bounds, reason: 'the box it was downloaded for');
    await r.s.show(tester, RegionsScreen(regions: r.regions, initialTab: 1));
    await tester.pump();
    final asks = r.s.maps.asks;
    // The hold menu.
    await tester.longPress(find.byKey(const ValueKey('local-$_county')));
    await tester.pumpAndSettle();
    expect(find.text('Show on map'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('region-action-showOnMap')));
    await tester.pumpAndSettle();
    expect(r.s.maps.asks, asks + 1);
    expect(r.s.maps.takeAreaAsk(), box);
    // Its page.
    await tester.tap(find.byKey(const ValueKey('local-$_county')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(RegionPage), findsOneWidget);
    final show = find.byKey(const ValueKey('region-show-on-map'));
    await tester.ensureVisible(show);
    await tester.pump();
    await tester.tap(show);
    await tester.pump();
    expect(r.s.maps.asks, asks + 2);
    expect(r.s.maps.takeAreaAsk(), box);
    await r.dispose(tester);
  });

  // Link audit, batch 2: a route error that names missing data gets the download for the route's area.
  testWidgets('Download this area: with nothing on the phone, the catalogue\'s region where to', (tester) async {
    final r = await _Rig.boot(tester);
    final b = r.county.bounds!;
    final inCounty = GeoPoint((b.south + b.north) / 2, (b.west + b.east) / 2);
    final ends = [inCounty];
    await r.s.show(tester, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => getRouteArea(c, r.regions, ends), child: const Text('go')))));
    // Nothing on the phone: the region where to.
    final here = r.catalogue.regionAt(inCounty.lat, inCounty.lon);
    expect(here, isNotNull);
    await tester.tap(find.text('go'));
    await r.settleUntil(tester, () => _shown(find.text('Download ${here!.name}?')));
    expect(find.text('Download ${here!.name}?'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('Download this area: where to is held by a region on the phone, the start is not: the start\'s region', (tester) async {
    final r2 = await _Rig.boot(tester);
    final b = r2.county.bounds!;
    final inCounty = GeoPoint((b.south + b.north) / 2, (b.west + b.east) / 2);
    final other = r2.us['us-ut']!.bounds!;
    final elsewhere = GeoPoint((other.south + other.north) / 2, (other.west + other.east) / 2);
    await tester.runAsync(() => r2.regions.download(r2.county, routing: true, map: true));
    r2.core.finish(_county);
    await r2.refreshUntil(tester, () => r2.regions.regionOf(_county)?.phase == RegionPhase.ready);
    expect(r2.regions.regionHolding(inCounty.lat, inCounty.lon, routing: true)?.id, _county);
    expect(r2.regions.regionHolding(elsewhere.lat, elsewhere.lon, routing: true), isNull);
    final ends = [inCounty, elsewhere];
    final there = r2.catalogue.regionAt(elsewhere.lat, elsewhere.lon);
    expect(there, isNotNull);
    await r2.s.show(tester, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => getRouteArea(c, r2.regions, ends), child: const Text('go')))));
    await tester.tap(find.text('go'));
    await r2.settleUntil(tester, () => _shown(find.text('Download ${there!.name}?')));
    expect(find.text('Download ${there!.name}?'), findsOneWidget);
    await r2.dispose(tester);
  });

  testWidgets('Download this area: where the catalogue names no region (the open sea), the Regions sheet at that place', (tester) async {
    final r3 = await _Rig.boot(tester);
    const ends = [GeoPoint(0.5, -150.0)];
    await r3.s.show(tester, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => getRouteArea(c, r3.regions, ends), child: const Text('go')))));
    await tester.tap(find.text('go'));
    await r3.settleUntil(tester, () => _shown(find.byType(RegionsListSheet)));
    expect(find.byType(RegionsListSheet), findsOneWidget);
    final sheet = tester.widget<RegionsListSheet>(find.byType(RegionsListSheet));
    expect((sheet.lat, sheet.lon), (0.5, -150.0));
    await r3.dispose(tester);
  });

  testWidgets('Add off-road data: the region on the phone that holds the route and has no off-road gets Add off-road', (tester) async {
    final r = await _Rig.boot(tester);
    await tester.runAsync(() => r.regions.download(r.county, routing: true, map: true));
    r.core.finish(_county);
    await r.refreshUntil(tester, () => r.regions.regionOf(_county)?.phase == RegionPhase.ready);
    final b = r.county.bounds!;
    final inCounty = GeoPoint((b.south + b.north) / 2, (b.west + b.east) / 2);
    expect(r.regions.regionHolding(inCounty.lat, inCounty.lon, withoutOffroad: true)?.id, _county);
    await r.s.show(tester, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => addRouteOffroad(c, r.regions, [inCounty]), child: const Text('go')))));
    await tester.tap(find.text('go'));
    await r.settleUntil(tester, () => _shown(find.text('Add off-road to ${r.county.name}?')));
    expect(find.text('Add off-road to ${r.county.name}?'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('Settings > Maps and the layer sheet open the regions screen', (tester) async {
    final r = await _Rig.boot(tester);
    final hub = SettingsHub(
      settings: r.s.settings,
      policy: r.s.policy,
      webSearch: r.s.webSearch,
      storage: r.s.storage,
      weather: r.s.weather,
      regions: r.regions,
    );
    final deps = SettingsDeps(
      app: r.s.app,
      chat: r.s.chat,
      sources: r.s.sources,
      maps: r.s.maps,
      video: r.s.video,
      browse: r.s.browse,
      location: r.s.location,
      hub: hub,
    );
    await r.s.show(tester, MapsPage(deps: deps));
    expect(find.text('Download a region'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('regions-row')));
    await tester.pumpAndSettle();
    expect(find.text('Regions'), findsOneWidget);
    expect(find.text('Downloads'), findsOneWidget);

    // a fresh app: the Regions screen opened above is still on top of the old one's navigator
    await tester.pumpWidget(const SizedBox());
    await r.s.show(tester, Scaffold(body: LayerSheet(maps: r.s.maps, location: r.s.location, regions: r.regions)));
    expect(find.text('Get more layers'), findsOneWidget, reason: 'the layer catalogue stays for single layers and drawn areas');
    await tester.ensureVisible(find.byKey(const ValueKey('download-region')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('download-region')));
    await tester.pumpAndSettle();
    expect(find.text('Downloads'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('a region whose known parts do not fit the phone is refused once, before any part starts', (tester) async {
    final r = await _Rig.boot(tester);
    var space = const Space(free: 200 << 30, reserve: 20 << 30);
    final regions = RegionsState(policy: r.s.policy, supportDir: () async => r.s.dir, catalogue: r.catalogue, maps: r.s.maps, opener: (_) async => r.core, spaceOf: (_) => space);
    await tester.runAsync(regions.init);
    final county = r.county;
    final cost = regions.costOf(county);
    final need = regions.knownDownloadBytes(county, routing: true, map: true);
    expect(need, cost.routing! + cost.map!, reason: 'the catalogue sizes the pop-up shows');
    // One byte short for directions and the map together. Each alone fits, and each alone is all that was ever checked: the
    // parts check themselves as they start, so both started.
    const reserve = 5 << 30;
    space = Space(free: reserve + need - 1, reserve: reserve);
    expect(space.shortBy(cost.routing!) + space.shortBy(cost.map!), 0);
    Object? refused;
    await tester.runAsync(() async {
      try {
        await regions.download(county, routing: true, map: true, anyway: true);
      } catch (e) {
        refused = e;
      }
    });
    expect(refused, isA<CacheSearchException>().having((e) => e.code, 'code', 'no_space'));
    expect(downloadProblemWords(refused!, what: 'download Twin Falls County'),
        "Couldn't download Twin Falls County: there is not enough free space. Free some space in Settings > Storage, then try again.");
    expect(r.core.added, isEmpty, reason: 'directions did not start');
    expect(r.s.engine.allAreas, isEmpty, reason: 'no map layer started');
    expect(regions.regionOf(_county), isNull, reason: 'nothing of it is on the phone, and nothing is left to clean up');
    // with room for all of it, it starts
    space = Space(free: reserve + need, reserve: reserve);
    await tester.runAsync(() => regions.download(county, routing: true, map: true, anyway: true));
    expect(r.core.added.single['id'], _county);
    expect(r.s.engine.allAreas, isNotEmpty);
    // A part with no size known is not counted (an area drawn on the map has none): it starts, and its own check stands.
    space = const Space(free: reserve, reserve: reserve);
    final drawn = RegionRecord.drawn(const GeoBounds(south: 42.5, west: -114.6, north: 42.6, east: -114.4), at: DateTime(2026, 11, 11));
    expect(regions.knownDownloadBytes(drawn, routing: true, map: true), 0);
    await tester.runAsync(() => regions.download(drawn, routing: true, map: false, anyway: true));
    expect(r.core.added.last['id'], drawn.id);
    regions.dispose();
    await r.dispose(tester);
  });

  testWidgets('a region\'s map downloads for its outline in every layer; an area drawn on the map for its box', (tester) async {
    final r = await _Rig.boot(tester);
    final g = (await tester.runAsync(() => r.catalogue.geometry(r.county)))!;
    final outline = mapOutline(r.county, g);
    expect(outline, isNotNull);
    await tester.runAsync(() => r.regions.download(r.county, routing: false, map: true));
    final asked = r.s.engine.outlineOf['Twin Falls County']!;
    expect(asked, isNotEmpty);
    expect(asked.values, everyElement(outline), reason: 'the same outline for each layer, the rings as the catalogue has them');
    // each layer is still sized for the box: the box is what the download is given as its area
    expect(r.s.engine.allAreas.map((a) => a.bounds), everyElement(r.county.bounds));

    final drawn = RegionRecord.drawn(const GeoBounds(south: 42.5, west: -114.6, north: 42.6, east: -114.4), at: DateTime(2026, 11, 11));
    await tester.runAsync(() => r.regions.download(drawn, routing: false, map: true, anyway: true));
    expect(r.s.engine.outlineOf[drawn.name]!.values, everyElement(isNull));
    await r.dispose(tester);
  });

  testWidgets('a region\'s map size is asked for its outline, so the size shown and the free-space check are the outline\'s, not the box\'s', (tester) async {
    final r = await _Rig.boot(tester);
    final g = (await tester.runAsync(() => r.catalogue.geometry(r.county)))!;
    final outline = mapOutline(r.county, g);
    expect(outline, isNotNull);
    r.s.engine.outlineShare = 0.6;
    final plan = (await tester.runAsync(() => r.regions.plan(r.county)))!;
    expect(r.s.engine.outlineAsked.values.expand((v) => v), everyElement(outline), reason: 'the plan asks for the outline, not the box');
    expect(plan.map, isNotEmpty);
    // The fake steps down to the deepest zoom that fits its limits, so the outline's smaller tile count can fit a deeper zoom: the
    // figure shown is the outline's own (what the engine says for the outline), and not the box's.
    final id = plan.map.first.def.id;
    final withOutline = await tester.runAsync(() => r.s.engine.estimate(id, r.county.bounds!, outline: outline));
    final box = await tester.runAsync(() => r.s.engine.estimate(id, r.county.bounds!));
    expect(plan.map.first.estimate.bytes, withOutline!.bytes, reason: 'the figure shown is the outline\'s');
    expect(plan.map.first.estimate.bytes, isNot(box!.bytes), reason: 'and not the box\'s');
    // an area drawn on the map has no outline: sized as its box
    final drawn = RegionRecord.drawn(const GeoBounds(south: 42.5, west: -114.6, north: 42.6, east: -114.4), at: DateTime(2026, 11, 11));
    r.s.engine.outlineAsked.clear();
    await tester.runAsync(() => r.regions.plan(drawn));
    expect(r.s.engine.outlineAsked.values.expand((v) => v), everyElement(isNull));
    await r.dispose(tester);
  });

  testWidgets('a region plan counts the tiles two layers keep in one store once (hillshade and contours share the elevation tiles)', (tester) async {
    final r = await _Rig.boot(tester);
    Map<String, dynamic> shade(String id) => {
          'format': 1,
          'id': id,
          'title': 'Shared $id',
          'description': 'd',
          'license': 'l',
          'attribution': 'a',
          'kind': 'hillshade',
          'transform': 'as_is',
          'derived_from': 'sharedsrc',
          'encoding': 'terrarium',
          'source': {'type': 'xyz', 'url': 'https://t.test/{z}/{x}/{y}.webp', 'minzoom': 0, 'maxzoom': 12, 'tile_size': 512},
          'approx_tile_bytes': 40000,
        };
    await tester.runAsync(() async {
      await r.s.engine.saveDefinition(jsonEncode(shade('sharedone')));
      await r.s.engine.saveDefinition(jsonEncode(shade('sharedtwo')));
      r.s.maps.setOn('sharedone', true);
      r.s.maps.setOn('sharedtwo', true);
    });
    expect(r.s.maps.isOn('sharedone') && r.s.maps.isOn('sharedtwo'), isTrue, reason: 'both are on');
    final plan = (await tester.runAsync(() => r.regions.plan(r.county)))!;
    final shared = plan.map.where((m) => r.s.engine.downloadLayerOf(m.def.id) == 'sharedsrc').toList();
    expect(shared, hasLength(1), reason: 'one estimate for the store, not one per layer that reads it');
    await r.dispose(tester);
  });

  testWidgets('directions with no road data for the area: its page says not available yet, as it does for places, not Ready', (tester) async {
    final r = await _Rig.boot(tester);
    await tester.runAsync(() async {
      await r.regions.download(r.county, routing: true, map: false);
      // The published roads have no tile over the area: the core has nothing to fetch and says "ready".
      r.core.regions[_county]!
        ..['state'] = 'ready'
        ..['tiles'] = 0
        ..['bytes'] = 0
        ..['done_tiles'] = 0
        ..['done_bytes'] = 0;
      await r.regions.refresh();
    });
    final l = r.regions.regionOf(_county)!;
    expect(l.parts.single.state, PartState.notAvailable);
    expect(l.phase, RegionPhase.ready);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: RegionPage(regions: r.regions, id: _county)));
    await r.settleUntil(tester, () => _shown(find.text('Not available yet for this area')));
    expect(find.descendant(of: find.byKey(const ValueKey('part-directions')), matching: find.text('Not available yet for this area')), findsOneWidget);
    expect(find.textContaining('Ready · '), findsNothing, reason: 'it read "Ready · 0 B", with a tick');
    // the same row places have: a tap says why
    await tester.tap(find.byKey(const ValueKey('part-directions')));
    await tester.pump();
    expect(find.byKey(const ValueKey('part-note')), findsOneWidget);
    await r.dispose(tester);
  });

  group('places and addresses', () {
    testWidgets('places are offered once they are published (the catalogue has their size), and downloaded first', (tester) async {
      final r = await _Rig.boot(tester, places: true);
      expect(r.config?['places_base_url'], kPlacesBaseUrl, reason: 'the engine is told where places are published');
      // The published catalogue has no places sizes yet: no region is offered places (they could only fail).
      expect(r.regions.offer(r.county).places, isFalse);
      final c = r.county;
      final withPlaces = RegionRecord(id: c.id, name: c.name, kind: c.kind, bbox: c.bbox, country: c.country,
          sizes: RegionSizes(routing: c.sizes!.routing, places: 16 << 20, map: c.sizes!.map, offroadPacks: c.sizes!.offroadPacks, offroadTerrain: c.sizes!.offroadTerrain));
      final o = r.regions.offer(withPlaces);
      expect(o.places, isTrue);
      expect(o.bytes, r.regions.offer(c).bytes! + (16 << 20));
      await tester.runAsync(() => r.regions.download(withPlaces, routing: o.routing, map: false, places: o.places, anyway: true));
      expect(r.core.added.single['parts'], ['places', 'routing']);
      expect(r.regions.regionOf(_county)!.hasPlaces, isTrue);

      // Places that cannot be planned say why; road routing is still planned.
      r.core.placesOffline = true;
      final p = (await tester.runAsync(() => r.regions.plan(r.us['us-ut']!)))!;
      expect(p.routing, isNotNull);
      expect(p.places, isNull);
      expect(p.placesProblem, 'Needs a connection to work out the size.');
      // Places not published for the area: plain words, not the server's answer.
      r.core.placesOffline = false;
      r.core.placesMissing = true;
      final q = (await tester.runAsync(() => r.regions.plan(r.us['us-ut']!)))!;
      expect(q.placesProblem, "Places for this area aren't available yet.");
      await r.dispose(tester);
    });

    test('download problems from the core are said in plain words', () {
      expect(regionPartWords(RegionPart.places, 'fetch_failed', 'HTTP 404 from https://data.cached.info/places/current.json'),
          "Places for this area aren't available yet.");
      expect(regionPartWords(RegionPart.routing, 'fetch_failed', 'HTTP 404 from https://x/routing.tar'), "Road routing for this area isn't available yet.");
      expect(regionPartWords(RegionPart.routing, 'fetch_failed', 'HTTP 503 from https://x/a'), "The download server couldn't send it just now. Try again later.");
      expect(regionPartWords(RegionPart.places, 'internal', 'checksum mismatch for https://x/a'), "Couldn't be downloaded. Try again later.");
      expect(regionPartWords(RegionPart.places, 'offline', 'the places server cannot be reached'), 'Needs a connection.');
      final s = LocalRegion(id: 'r', name: 'R', places: {'state': 'failed', 'error': 'HTTP 404 from https://data.cached.info/places/x.pack'});
      expect(s.error, "Places for this area aren't available yet.");
    });

    test('a downloading part shows its speed and time left, so a slow part never looks stuck', () {
      var now = DateTime(2026, 10, 31, 12);
      final meter = TransferMeter(clock: () => now);
      LocalRegion at(int done, int total) => LocalRegion(id: 'r', name: 'R', meter: meter, routing: {'state': 'downloading', 'bytes': total, 'done_bytes': done});
      // the first look has nothing to measure from
      expect(at(0, 100 << 20).parts.single.words, '0%');
      now = now.add(const Duration(seconds: 10));
      final p = at(20 << 20, 100 << 20).parts.single;
      expect(p.rate!.speedWords, '2.1 MB/s');
      expect(p.words, '20% · 2.1 MB/s · 40 s left');
      expect(partStateWords(p), '20% · 2.1 MB/s · 40 s left');
      expect(at(20 << 20, 100 << 20).partsLine, 'Directions 20% · 2.1 MB/s · 40 s left');
      // the map part has no byte total: its time left comes from how fast its share of tiles grows
      final meter2 = TransferMeter(clock: () => now);
      DownloadedArea area(int done) => DownloadedArea(id: 'a', layerId: 'basemap', bounds: const GeoBounds(west: 0, south: 0, east: 1, north: 1), label: 'R', minZoom: 0, maxZoom: 15, totalTiles: 1000, doneTiles: done, bytes: done * 1000);
      LocalRegion map(int done) => LocalRegion(id: 'm', name: 'M', meter: meter2, areas: [area(done)]);
      expect(map(100).parts.single.words, '10%', reason: 'the first look has nothing to measure from');
      now = now.add(const Duration(minutes: 1));
      expect(map(200).parts.single.words, '20% · 2 KB/s · 8 min left');
      expect(const TransferRate(secondsLeft: 4800).leftWords, '1 h 20 min left');
      expect(const TransferRate(secondsLeft: 7200).leftWords, '2 h left');
    });

    test('places not published for the area: not available yet, the region complete, nothing to try again', () {
      // the places server has no current.json
      final none = LocalRegion(id: 'r', name: 'R', routing: {'state': 'ready', 'bytes': 100}, places: {'state': 'failed', 'error': 'HTTP 404 from https://data.cached.info/places/current.json'});
      final p = none.parts.firstWhere((p) => p.kind == RegionPartKind.places);
      expect(p.state, PartState.notAvailable);
      expect(p.complete, isTrue);
      expect(p.problem, isNull);
      expect(partStateWords(p), 'Not available yet');
      expect(none.placesNotAvailable, isTrue);
      expect(none.phase, RegionPhase.ready);
      expect(none.error, isNull);
      expect(none.fraction, 1.0);
      expect(none.partsLine, 'Places not available yet');
      // the published index has no tile over the area
      final empty = LocalRegion(id: 'r', name: 'R', routing: {'state': 'ready', 'bytes': 100}, places: {'state': 'ready', 'tiles': 0, 'bytes': 0});
      expect(empty.placesNotAvailable, isTrue);
      expect(empty.phase, RegionPhase.ready);
      // places that do exist and fail to download stay a failure, with its fix
      final tile = LocalRegion(id: 'r', name: 'R', routing: {'state': 'ready', 'bytes': 100}, places: {'state': 'failed', 'error': 'HTTP 404 from https://data.cached.info/places/b1/1/2/3.sqlite.gz'});
      expect(tile.placesNotAvailable, isFalse);
      expect(tile.phase, RegionPhase.failed);
      final busy = LocalRegion(id: 'r', name: 'R', routing: {'state': 'ready', 'bytes': 100}, places: {'state': 'failed', 'error': 'HTTP 503 from https://data.cached.info/places/current.json'});
      expect(busy.phase, RegionPhase.failed);
      expect(placesNotPublished('HTTP 410 from https://x/places/current.json'), isTrue);
      expect(placesNotPublished('HTTP 404 from https://x/places/index-b1.json.gz'), isFalse);
      expect(placesNotPublished(null), isFalse);
    });

    test('directions with no road data for the area read as places do there: not available yet, never Ready with nothing', () {
      // the published roads have no tile over the area (an area drawn outside them): the core says "ready" with 0 tiles
      final none = LocalRegion(
        id: 'drawn-1',
        name: 'Drawn area',
        routing: {'state': 'ready', 'tiles': 0, 'bytes': 0, 'done_tiles': 0, 'done_bytes': 0, 'error': null},
        places: {'state': 'ready', 'tiles': 4, 'bytes': 20, 'done_tiles': 4, 'done_bytes': 20},
      );
      final d = none.parts.firstWhere((p) => p.kind == RegionPartKind.directions);
      expect(d.state, PartState.notAvailable);
      expect(d.ready, isFalse);
      expect(d.complete, isTrue);
      expect(d.problem, isNull);
      expect(partStateWords(d), 'Not available yet');
      expect(none.phase, RegionPhase.ready, reason: 'nothing more will come for it: the region is complete, with nothing to try again');
      expect(none.error, isNull);
      expect(none.fraction, 1.0);
      expect(none.partsLine, 'Directions not available yet');
      expect(none.notAvailableNotes, ['Directions not available yet']);
      expect(regionDoneLine(none), 'On this device · ${formatBytes(none.bytes)} · Directions not available yet');
      // places in the same situation say it in the same words, the ones their row has always had
      final noPlaces = LocalRegion(id: 'r', name: 'R', routing: {'state': 'ready', 'tiles': 4, 'bytes': 100}, places: {'state': 'ready', 'tiles': 0, 'bytes': 0});
      expect(noPlaces.notAvailableNotes, [kPlacesNotAvailableShort]);
      expect(regionDoneLine(noPlaces), 'On this device · ${formatBytes(noPlaces.bytes)} · $kPlacesNotAvailableShort');
      // road data that is there reads ready as before, also from a core that names no tile count
      expect(LocalRegion(id: 'r', name: 'R', routing: {'state': 'ready', 'tiles': 4, 'bytes': 100}).parts.single.state, PartState.ready);
      expect(LocalRegion(id: 'r', name: 'R', routing: {'state': 'ready', 'bytes': 100}).parts.single.state, PartState.ready);
      expect(LocalRegion(id: 'r', name: 'R', routing: {'state': 'ready', 'bytes': 100}).notAvailableNotes, isEmpty);
      // and a part still working out what it needs is downloading, not "not available"
      expect(LocalRegion(id: 'r', name: 'R', routing: {'state': 'downloading', 'tiles': 0, 'bytes': 0}).parts.single.state, PartState.downloading);
    });

    testWidgets('places published after a region was downloaded: Check for update finds them, its page offers them, Update adds them', (tester) async {
      final r = await _Rig.boot(tester, places: true, placesBuildOnlyWithRegion: true);
      await tester.runAsync(() async {
        await r.regions.download(r.us['us-id']!, routing: true, map: false);
        r.core.finish('us-id');
        await r.regions.refresh();
      });
      expect(r.regions.regionOf('us-id')!.hasPlaces, isFalse);
      expect(r.regions.placesPublished, isFalse, reason: 'the core names a places build only once a region has places');
      expect(r.regions.placesNowAvailable(r.regions.regionOf('us-id')!), isFalse);
      await tester.runAsync(r.regions.checkUpdates);
      expect(r.regions.placesNowAvailable(r.regions.regionOf('us-id')!), isTrue, reason: 'check_update read the server: places are published');
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: RegionPage(regions: r.regions, id: 'us-id')));
      await r.settleUntil(tester, () => _shown(find.byKey(const ValueKey('part-places-add'))));
      expect(find.byKey(const ValueKey('part-places-add')), findsOneWidget);
      expect(find.text('Now available'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-places')), findsOneWidget);
      await tester.runAsync(() => r.regions.updateRegion('us-id', anyway: true));
      await r.settleUntil(tester, () => r.regions.regionOf('us-id')!.hasPlaces && _shown(find.byKey(const ValueKey('part-places'))));
      expect(r.regions.regionOf('us-id')!.hasPlaces, isTrue, reason: 'Update adds the newly published part');
      expect(find.byKey(const ValueKey('part-places-add')), findsNothing);
      expect(find.byKey(const ValueKey('part-places')), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('a part waiting for a core that does not list the region is stopped and offers Carry on, which asks again', (tester) async {
      final r = await _Rig.boot(tester, places: true);
      await tester.runAsync(() async {
        await r.regions.download(r.us['us-id']!, routing: true, map: false, places: true);
        await r.regions.refresh();
      });
      expect(r.regions.regionOf('us-id')!.phase, RegionPhase.downloading);
      // the state 1.0.28 left: the app keeps the region, the core never listed it (its add failed before places were published)
      r.core.regions.remove('us-id');
      final again = RegionsState(policy: r.s.policy, supportDir: () async => r.s.dir, catalogue: r.catalogue, maps: r.s.maps, opener: (_) async => r.core);
      await tester.runAsync(again.init);
      await r.settleUntil(tester, () => again.regionOf('us-id')?.phase == RegionPhase.stopped);
      final l = again.regionOf('us-id')!;
      expect([for (final p in l.parts) (p.kind, p.state)], [(RegionPartKind.directions, PartState.stopped), (RegionPartKind.places, PartState.stopped)],
          reason: 'not "waiting" for ever: nothing is queued for it');
      expect(l.phase, RegionPhase.stopped);
      expect(again.offer(r.us['us-id']!).kind, RegionOfferKind.carryOn);
      await tester.runAsync(() => again.carryOn('us-id'));
      expect(r.core.added.last['parts'], ['places', 'routing']);
      expect(again.regionOf('us-id')!.phase, RegionPhase.downloading, reason: 'asked again: the parts download');
      again.dispose();
      await r.dispose(tester);
    });

    testWidgets('a region downloaded before places were published gets them at the next start, once they are', (tester) async {
      final r = await _Rig.boot(tester, places: true);
      await tester.runAsync(() async {
        await r.regions.download(r.us['us-id']!, routing: true, map: false, places: true);
        r.core.finish('us-id', part: 'routing');
        // places were not published then: the core's places part failed for want of current.json
        final parts = r.core.regions['us-id']!['parts'] as Map<String, dynamic>;
        parts['places'] = {'state': 'failed', 'tiles': 0, 'bytes': 0, 'done_tiles': 0, 'done_bytes': 0, 'error': 'HTTP 404 from https://data.cached.info/places/current.json'};
        await r.regions.refresh();
      });
      final before = r.regions.regionOf('us-id')!;
      expect(before.placesNotAvailable, isTrue);
      expect(before.phase, RegionPhase.ready);
      final adds = r.core.added.length;
      // places are published now (the core reads a build); the app starts again
      final again = RegionsState(policy: r.s.policy, supportDir: () async => r.s.dir, catalogue: r.catalogue, maps: r.s.maps, opener: (_) async => r.core);
      await tester.runAsync(() async {
        await again.init();
        await again.recheckPublished();
      });
      expect(r.core.added.length, greaterThan(adds));
      expect(r.core.added.last['parts'], ['places']);
      final now = again.regionOf('us-id')!;
      expect(now.placesNotAvailable, isFalse);
      expect(now.parts.firstWhere((p) => p.kind == RegionPartKind.places).state, PartState.downloading);
      again.dispose();
      await r.dispose(tester);
    });

    testWidgets('Local names the parts; a region from before places offers them, and Update adds only that part', (tester) async {
      final r = await _Rig.boot(tester, places: true);
      await tester.runAsync(() async {
        await r.regions.download(r.us['us-id']!, routing: true, map: false, places: true);
        await r.regions.download(r.county, routing: true, map: true);
      });
      r.core.finish('us-id');
      r.core.finish(_county);
      await r.refreshUntil(tester, () => r.regions.regionOf('us-id')?.phase == RegionPhase.ready && r.regions.regionOf(_county)?.phase == RegionPhase.ready);
      await r.s.show(tester, RegionsScreen(regions: r.regions, initialTab: 1));
      await tester.pump();
      expect(find.text('On this device · ${formatBytes(140 << 20)}'), findsOneWidget);
      expect(r.regions.missesPlaces(r.regions.regionOf(_county)!), isTrue);
      expect(r.core.added.last['parts'], ['routing']);

      await tester.longPress(find.byKey(const ValueKey('local-$_county')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('region-action-update')));
      await r.settleUntil(tester, () => r.core.added.last['id'] == _county && (r.core.added.last['parts'] as List).join(',') == 'places');
      expect(r.core.added.last['id'], _county);
      expect(r.core.added.last['parts'], ['places'], reason: 'only the missing part');
      r.core.finish(_county);
      await tester.runAsync(r.regions.refresh);
      await tester.pump();
      expect(r.regions.regionOf(_county)!.hasPlaces, isTrue);
      expect(r.regions.missesPlaces(r.regions.regionOf(_county)!), isFalse);

      await tester.longPress(find.byKey(const ValueKey('local-$_county')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('region-action-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete this region?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await r.dispose(tester);
    });

    testWidgets('a places part that fails fails the region, with its reason', (tester) async {
      final r = await _Rig.boot(tester, places: true);
      await tester.runAsync(() async {
        await r.regions.download(r.county, routing: true, map: false, places: true);
        r.core.finish(_county, part: 'routing');
        final p = (r.core.regions[_county]!['parts'] as Map)['places'] as Map;
        p
          ..['state'] = 'failed'
          ..['error'] = 'A places tile did not match its check';
        r.core.regions[_county]!['state'] = 'failed';
        await r.regions.refresh();
      });
      expect(r.regions.regionOf(_county)!.phase, RegionPhase.failed);
      expect(r.regions.regionOf(_county)!.error, 'A places tile did not match its check');
      await r.dispose(tester);
    });

    testWidgets('Updates has a Places group: a new build, Update all starts it', (tester) async {
      final r = await _Rig.boot(tester, places: true);
      await tester.runAsync(() async {
        await r.regions.download(r.county, routing: true, map: false, places: true);
        r.core.finish(_county);
        await r.regions.refresh();
      });
      await r.s.show(tester, RegionsScreen(regions: r.regions, initialTab: 2));
      await tester.pump();
      expect(find.text('PLACES'), findsOneWidget);
      expect(find.text('Up to date'), findsNWidgets(2));

      r.core.placesUpdate = {'build': 'na-places-2026-12-15', 'download_bytes': 23 << 20, 'downloading': false};
      await tester.tap(find.text('Check for updates'));
      await r.settleUntil(tester, () => _shown(find.text('New places')));
      expect(find.text('New places'), findsOneWidget);
      expect(find.text('na-places-2026-12-15 · About 23 MB to download'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const ValueKey('update-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('update-all')));
      await r.settleUntil(tester, () => _shown(find.text('Downloading na-places-2026-12-15')));
      expect(r.core.calls.where((c) => c == 'update'), hasLength(1), reason: 'only places had a new build');
      expect(find.text('Downloading na-places-2026-12-15'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('when the places on the phone change, the callback runs once per change', (tester) async {
      var changed = 0;
      final r = await _Rig.boot(tester, places: true, onPlacesChanged: () async => changed++);
      expect(changed, 0, reason: 'the first status only sets where it starts');
      await tester.runAsync(() async {
        await r.regions.download(r.county, routing: false, map: false, places: true);
        await r.regions.refresh();
      });
      expect(changed, 0);
      r.core.finish(_county);
      await tester.runAsync(r.regions.refresh);
      expect(changed, 1);
      await tester.runAsync(r.regions.refresh);
      expect(changed, 1);
      await tester.runAsync(() => r.regions.remove(_county));
      expect(changed, 2);
      await r.dispose(tester);
    });

    testWidgets('the map search with no places offers a region, and Get a region opens Downloads', (tester) async {
      final r = await _Rig.boot(tester, places: true);
      final backend = FakeBackend()
        ..onSearch = (q, {near, meaning}) async => MapSearchResponse(
              query: q,
              kind: 'text',
              meaning: 'off',
              results: const [],
              warningCode: 'no_places',
              places: const PlacesCoverage(installed: false, covers: false),
            );
      final nav = NavState(
        backend: backend,
        location: r.s.location,
        speaker: FakeSpeaker(),
        positionSource: FakeNavPosition(),
        fmt: const Fmt(UnitSystem.imperial),
        searchDebounce: const Duration(milliseconds: 1),
        meaningDebounce: const Duration(milliseconds: 2),
      );
      await r.s.show(tester, Scaffold(body: SafeArea(child: NavSearchBar(nav: nav, fmt: nav.fmt, regions: r.regions))));
      await tester.enterText(find.byKey(const ValueKey('map-search-field')), 'pharmacy');
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      expect(find.text('No places on this device.'), findsOneWidget);
      expect(find.text('Download a region to search places and addresses.'), findsOneWidget);
      expect(find.text('Nothing found for "pharmacy"'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('get-region')));
      await tester.pumpAndSettle();
      expect(find.text('Regions'), findsOneWidget);
      expect(find.byKey(const ValueKey('region-search')), findsOneWidget, reason: 'the Downloads tab');
      await tester.pumpWidget(const SizedBox());
      nav.dispose();
      await r.dispose(tester);
    });
  });

  testWidgets('the Regions sheet: the regions at a place with their sizes; Select ticks several and one Download goes through the pop-up', (tester) async {
    final r = await _Rig.boot(tester);
    final b = r.county.bounds!;
    await r.s.show(tester, Scaffold(body: Builder(builder: (c) => TextButton(
      onPressed: () => showRegionsSheet(c, r.regions, lat: (b.south + b.north) / 2, lon: (b.west + b.east) / 2),
      child: const Text('open'),
    ))));
    await tester.tap(find.text('open'));
    await r.settleUntil(tester, () => _shown(find.text('Twin Falls County')));
    expect(find.text('Regions'), findsOneWidget);
    expect(find.text('Each region has directions, map, places and off-road.'), findsOneWidget);
    expect(find.textContaining('County · ${formatBytes(r.regions.offer(r.county).bytes!)}'), findsOneWidget, reason: 'sizes at once');
    expect(find.text('Twin Falls County'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing, reason: 'no tick boxes until Select');
    expect(find.byTooltip('Download Twin Falls County'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('regions-select')));
    await tester.pump();
    expect(find.byType(Checkbox), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('region-$_county')));
    await tester.pump();
    expect(find.textContaining('Download 1 ·'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('regions-download-picked')));
    await r.settleUntil(tester, () => _shown(find.text('Download Twin Falls County?')));
    expect(find.text('Download Twin Falls County?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-download')));
    await r.settleUntil(tester, () => r.core.added.isNotEmpty);
    expect(r.core.added.single['id'], _county);
    await r.dispose(tester);
  });

  testWidgets('Draw your own area instead: the map draws, then the drawn area downloads as a region through the same sheet', (tester) async {
    final r = await _Rig.boot(tester);
    await tester.runAsync(() => r.catalogue.readShardAt(42.55, -114.4));
    await r.s.show(tester, Builder(builder: (c) => TextButton(onPressed: () => showRegionsSheet(c, r.regions, lat: 42.55, lon: -114.4), child: const Text('open'))));
    await tester.tap(find.text('open'));
    await r.settleUntil(tester, () => _shown(find.byKey(const ValueKey('regions-draw'))));
    await tester.tap(find.byKey(const ValueKey('regions-draw')));
    await r.settleUntil(tester, () => r.s.maps.drawRequest);
    expect(r.s.maps.drawRequest, isTrue, reason: 'the map is asked to draw');
    // what the map does with the rectangle: a region record of it, downloaded like any other
    final drawn = RegionRecord.drawn(const GeoBounds(south: 42.5, west: -114.5, north: 42.6, east: -114.3), at: DateTime(2026, 10, 30));
    expect((drawn.name, regionKindLabel(drawn.kind)), ('Drawn area', 'Drawn on the map'));
    final g = (await tester.runAsync(() => r.catalogue.geometry(drawn)))!;
    expect(g, {
      'type': 'Polygon',
      'coordinates': [
        [[-114.5, 42.5], [-114.3, 42.5], [-114.3, 42.6], [-114.5, 42.6], [-114.5, 42.5]],
      ],
    });
    await tester.runAsync(() => r.regions.download(drawn, routing: true, map: true, anyway: true));
    await r.settleUntil(tester, () => r.core.added.isNotEmpty && r.s.engine.areasOf('basemap').isNotEmpty);
    expect(r.core.added.single['geometry'], g);
    expect(r.s.engine.areasOf('basemap').single.label, 'Drawn area');
    await r.dispose(tester);
  });

  testWidgets('Draw your own area from Home: the map, built only now, opens drawing; the drawn area goes to the same sheet', (tester) async {
    final r = await _Rig.boot(tester);
    final before = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = () => NoSurface();
    addTearDown(() => MapLibrePlatform.createInstance = before);
    final location = LocationService(source: FakeSource(), settingsDirOverride: r.s.dir);
    final nav = NavState(
      backend: FakeBackend(),
      location: location,
      speaker: FakeSpeaker(),
      positionSource: FakeNavPosition(),
      fmt: const Fmt(UnitSystem.imperial),
    );
    await tester.runAsync(() => r.catalogue.readShardAt(42.55, -114.4));
    // Home's "Get your area": the Regions sheet over Home, with no map on screen yet.
    await r.s.show(tester, Builder(builder: (c) => TextButton(onPressed: () => showRegionsSheet(c, r.regions, lat: 42.55, lon: -114.4), child: const Text('open'))));
    await tester.tap(find.text('open'));
    await r.settleUntil(tester, () => _shown(find.byKey(const ValueKey('regions-draw'))));
    await tester.tap(find.byKey(const ValueKey('regions-draw')));
    await r.settleUntil(tester, () => !_shown(find.text('Draw your own area instead')));
    expect(find.text('Draw your own area instead'), findsNothing, reason: 'the sheet closed');
    // The shell opens the Maps tab for the request; the map screen is built then, after the request was made.
    await r.s.show(tester, MapsScreen(
      location: location,
      maps: r.s.maps,
      nav: nav,
      themeId: CacheThemeId.dark,
      regions: r.regions,
      glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf',
    ));
    for (var i = 0; i < 100 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.text('Drag on the map to draw the area to download'), findsOneWidget, reason: 'the request was not lost');
    expect(r.s.maps.drawRequest, isFalse, reason: 'taken once');
    expect(find.text('Use this area'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    await r.dispose(tester);
  });

  testWidgets('the search field does not take the focus back when the region sheet closes', (tester) async {
    final r = await _Rig.boot(tester);
    await r.s.show(tester, RegionsScreen(regions: r.regions));
    await _openCountySheet(tester);
    await r.settleUntil(tester, () => _shown(find.text('Download Twin Falls County?')));
    expect(find.text('Download Twin Falls County?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Download Twin Falls County?'), findsNothing);
    final field = tester.widget<EditableText>(find.descendant(of: find.byKey(const ValueKey('region-search')), matching: find.byType(EditableText)));
    expect(field.focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse, reason: 'no keyboard');
    await r.dispose(tester);
  });
}
