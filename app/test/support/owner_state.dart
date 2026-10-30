import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/browse/zim_download.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/regions/offroad_catalogue.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/settings/hub.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'regions_fake.dart';
import 'settings_rig.dart';
import 'test_layer_engine.dart';
import 'weather_fakes.dart';

/// An off-road pack download that has started and not got anywhere yet (the region's off-road part waits).
class WaitingPacks extends ZimDownloader {
  final Completer<DownloadResult> _never = Completer<DownloadResult>();

  @override
  Future<DownloadResult> download({
    required Uri url,
    required File part,
    Uri? sha256Url,
    Uri? md5Url,
    String? expectedSha256,
    void Function(int done, int total)? onProgress,
    void Function()? onVerifying,
    CancelToken? cancel,
  }) =>
      _never.future;
}

Map<String, dynamic> offroadPack(String id, String name, List<double> bbox, int bytes) => {
  'id': id,
  'name': name,
  'country': 'US',
  'bbox': bbox,
  'build': 'offroad-2026-10',
  'land_access': 'us',
  'bytes': bytes + 100,
  'files': {
    'offroad.sqlite': {'path': 'offroad-2026-10/$id/offroad.sqlite', 'url': '${kOffroadBaseUrl}offroad-2026-10/$id/offroad.sqlite', 'bytes': bytes, 'sha256': 'ab' * 32},
  },
};

const List<double> kIdahoBox = [-117.24, 41.99, -111.04, 49.0];

/// The phone as the owner tested 1.0.27 with it: map downloads made layer by layer by 1.0.0 builds over Idaho (hillshade twice, the
/// BLM and motor vehicle use maps, and a Forest Service download that stopped part way), and the Idaho region downloaded by a later
/// build, partly: directions ready, places 40%, off-road waiting. [legacyOutside] adds an old download outside every region.
class OwnerState {
  late SettingsRig s;
  late FakeRegions core;
  late RegionCatalogue catalogue;
  late RegionsState regions;
  late RegionShard us;
  late FakeWeb offroadWeb;

  RegionRecord get idaho => us['us-id']!;

  /// The 1.0.0 per-layer downloads, by name.
  final Map<String, DownloadedArea> legacy = {};

  static Future<OwnerState> boot(WidgetTester tester, {bool legacyOutside = false, bool legacyFiles = true, bool idaho = true}) async {
    final o = OwnerState();
    o.s = await SettingsRig.create(tester);
    o.core = FakeRegions(tileDir: '${o.s.dir.path}/regions/tiles/2026-10')..placesEnabled = true;
    Directory(o.core.tileDir).createSync(recursive: true);
    final web = regionWeb();
    o.offroadWeb = FakeWeb()
      ..files['${kOffroadBaseUrl}current.json'] = utf8.encode(jsonEncode({
        'format': 1,
        'component': 'offroad',
        'base_url': kOffroadBaseUrl,
        'elevation': {'minzoom': 12, 'maxzoom': 12},
        'regions': [offroadPack('idaho', 'Idaho', [-118.0, 41.5, -110.3, 49.5], 1022825920)],
      }));
    o.catalogue = RegionCatalogue(dir: () async => Directory('${o.s.dir.path}/region-catalogue'), fetch: web.fetch);
    final e = o.s.engine;
    await tester.runAsync(() async {
      await e.saveDefinition(File('../packages/cache_search/layers/mapterhorn.json').readAsStringSync());
      // A state is a big download: the test engine's limits are raised so the old per-layer downloads of Idaho fit, as they did.
      Map<String, dynamic> big(Map<String, dynamic> l) =>
          {...l, 'download_limit_tiles': 1 << 30, 'download_limit_bytes': 1 << 40, 'approx_tile_bytes': l['approx_tile_bytes'] ?? 9000};
      for (final l in TestLayerEngine.layersOf(File('test/fixtures/catalogue.json').readAsStringSync())) {
        await e.saveDefinition(jsonEncode(big(l)));
      }
      await e.saveDefinition(jsonEncode(big(e.layer('hillshade')!.toJson())));
      for (final id in ['blm-routes', 'mvum', 'usfs-trails-roads', 'hillshade']) {
        o.s.maps.setOn(id, true);
      }
      o.us = await o.catalogue.shard('us');
      await o.catalogue.geometry(o.us['us-id']!);
      final box = o.us['us-id']!.bounds!;
      if (legacyFiles) {
        // 1.0.0: each layer downloaded on its own for the area, labelled with the area's name.
        Future<DownloadedArea> get(String layer) async => e.download(layer, box, label: 'Idaho');
        o.legacy['hillshade'] = await get('hillshade');
        o.legacy['hillshade again'] = await get('hillshade');
        o.legacy['blm'] = await get('blm-routes-idaho');
        o.legacy['mvum'] = await get('mvum-idaho');
        o.legacy['usfs'] = await get('usfs-trails-roads-idaho');
        if (legacyOutside) {
          final moab = o.us['us-ut']!.bounds!;
          o.legacy['moab'] = await e.download('hillshade', moab, label: 'Utah');
        }
        await Future<void>.delayed(const Duration(milliseconds: 80));
        // What each holds, as the published catalogue sizes Idaho's layers (the test engine counts 1000 bytes a tile).
        const mb = 1000 * 1000;
        o.legacy['hillshade']!.bytes = 302 * mb;
        o.legacy['hillshade again']!.bytes = 302 * mb;
        o.legacy['blm']!.bytes = 15 * mb;
        o.legacy['mvum']!.bytes = 65 * mb;
        // The Forest Service download stopped part way (Cache was closed while it ran): 40% of its 98 MB.
        final usfs = o.legacy['usfs']!;
        usfs
          ..phase = AreaPhase.failed
          ..interrupted = true
          ..error = 'Stopped before it finished. Tap Update to continue.'
          ..doneTiles = (usfs.totalTiles * 0.4).round()
          ..bytes = 39 * mb;
      }
      if (idaho) {
        // A later build downloaded Idaho as a region: directions and places from the core, off-road from its pack.
        o.core.sizes['us-id'] = 112629848; // the catalogue's directions size for Idaho
        await o.core.call('add', {'id': 'us-id', 'name': 'Idaho', 'geometry': {}, 'parts': ['routing', 'places']});
        o.core.finish('us-id', part: 'routing');
        final places = ((o.core.regions['us-id']!['parts'] as Map)['places'] as Map<String, dynamic>);
        places['bytes'] = 160 << 20;
        places['done_bytes'] = 64 << 20;
        File('${o.s.dir.path}/$kRegionsAppFile').writeAsStringSync(jsonEncode({
          'regions': {
            'us-id': {
              'name': 'Idaho',
              'routing': true,
              'places': true,
              'areas': [],
              'offroad': [
                {'path': 'offroad-2026-10/idaho/offroad.sqlite', 'name': 'Idaho', 'url': '${kOffroadBaseUrl}offroad-2026-10/idaho/offroad.sqlite', 'bytes': 1022825920, 'sha256': 'ab' * 32},
              ],
            },
          },
        }));
      }
      o.regions = RegionsState(
        policy: o.s.policy,
        supportDir: () async => o.s.dir,
        catalogue: o.catalogue,
        maps: o.s.maps,
        opener: (_) async => o.core,
        offroadCatalogue: OffroadCatalogue(dir: () async => Directory('${o.s.dir.path}/region-catalogue'), fetch: o.offroadWeb.fetch),
        packDownloader: WaitingPacks(),
      );
      // Settings reads the regions from the hub.
      o.s.hub = SettingsHub(
        sharing: o.s.sharing,
        settings: o.s.settings,
        policy: o.s.policy,
        webSearch: o.s.webSearch,
        storage: o.s.storage,
        weather: o.s.weather,
        regions: o.regions,
        openUrl: (u) async {},
      );
      await o.regions.init();
      await o.regions.migrateOldDownloads();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    return o;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    await s.dispose(tester);
  }
}
