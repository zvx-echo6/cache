// Maps two-writer proof: one device = one OS process running this file (flutter test --timeout none test/mapsproof/device.dart).
// Real parts: the app's SharingState over the real cache_sync SyncCore (iroh on localhost; relay, dht, mdns and lookup off), the
// Regions kind's `maps` and `regions` shares with the not-shared patterns of the build under test, the real core's layer engine (area
// downloads into a merged tile store, the tile server) through the app's CoreLayerEngine and MapsState, the app's RegionsState over the
// real region engine, and the region download through RegionsState.download (map part). Stand-ins: a fixed wifi probe, a tile host on
// 127.0.0.1 in this process that answers every tile with bytes naming the device (so which device's tile is served shows), and no
// routing or places part (their downloads need the data server; their sharing is tested in cache_regions/cache_places/cache_sync).
// Uses only API that rel-1.1 before the fix and after it share.
//
// Commands: <PROOF_DIR>/cmd/NNNN.json {"op","args"} -> <PROOF_DIR>/res/NNNN.json {"ok","result"|"error"}.
// Env: PROOF_DIR, PROOF_PORT, PROOF_NAME, PROOF_FIXED (1: the patterns of the fix).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/core_layer_engine.dart';
import 'package:cache/maps/layers/layer_def.dart' show AreaPhase, DownloadedArea;
import 'package:cache/maps/layers/layer_engine.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/search/core_config.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_test/flutter_test.dart';

// The not-shared patterns of the Regions kind (app/lib/sharing/share_rules.dart): the builds before the fix, and the fix (copied here so
// this file compiles on both).
const _regionsBefore = ['index', 'places/index', '**/*-shm', '**/*-journal'];
const _mapsBefore = ['tiles.sqlite*', 'tilejson', '**/*-shm', '**/*-journal'];
const _regionsFixed = ['index', 'places/index', '**/*-shm', '**/*-journal', 'regions.sqlite*', 'places/*.sqlite*', 'places/*/common.sqlite*', 'places/CURRENT', '**/* (conflict, *'];
const _mapsFixed = ['tiles.sqlite*', 'tilejson', '**/*-shm', '**/*-journal', 'store/*.sqlite*', '**/* (conflict, *'];

class _Probe implements ConnectionProbe {
  ConnectionKind kind = ConnectionKind.wifi;
  final _c = StreamController<ConnectionKind>.broadcast();
  void set(ConnectionKind k) {
    kind = k;
    _c.add(k);
  }

  @override
  Future<ConnectionKind> current() async => kind;
  @override
  Stream<ConnectionKind> get changes => _c.stream;
}

class _Real implements SyncCoreLike {
  _Real(this.c);
  final SyncCore c;
  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) => c.call(method, args);
  @override
  Future<void> close() => c.close();
}

void main() {
  final env = Platform.environment;
  test('device', timeout: Timeout.none, skip: env['PROOF_DIR'] == null ? 'PROOF_DIR not set' : false, () async {
    final root = Directory(env['PROOF_DIR']!)..createSync(recursive: true);
    final support = Directory('${root.path}/data')..createSync(recursive: true);
    final port = int.parse(env['PROOF_PORT']!);
    final name = env['PROOF_NAME'] ?? 'Device';
    final fixed = env['PROOF_FIXED'] == '1';
    final layersDir = Directory('${support.path}/layers')..createSync(recursive: true);
    final regionsDir = Directory('${support.path}/regions')..createSync(recursive: true);
    final settingsDir = Directory('${support.path}/settings')..createSync(recursive: true);
    void log(String s) => File('${root.path}/log.txt').writeAsStringSync('${DateTime.now().toIso8601String()} $s\n', mode: FileMode.append, flush: true);

    // the tile host: every tile is the bytes "<device>:<z>/<x>/<y>"
    final host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host.listen((req) {
      final p = req.uri.pathSegments;
      final m = p.length == 3 ? RegExp(r'^(\d+)\.mvt$').firstMatch(p[2]) : null;
      if (m == null) {
        req.response.statusCode = 404;
      } else {
        req.response.add(utf8.encode('$name:${p[0]}/${p[1]}/${m.group(1)}'));
      }
      req.response.close();
    });

    // the layer's definition: a read-only starter definition of this device (user definitions sync, and carry this device's port)
    Directory('${support.path}/layer-defs').createSync(recursive: true);
    File('${support.path}/layer-defs/basemap.json').writeAsStringSync(jsonEncode({
      'format': 1,
      'id': 'basemap',
      'title': 'Base map',
      'kind': 'vector',
      'transform': 'as_is',
      'source': {'type': 'xyz', 'url': 'http://127.0.0.1:${host.port}/{z}/{x}/{y}.mvt', 'tile_format': 'mvt', 'minzoom': 0, 'maxzoom': 14},
      'offline': {'allowed': true, 'max_tiles_per_download': 100000},
      'update': {'version': '1'},
      'coverage': {'bbox': [-180, -85, 180, 85]},
    }));
    final extras = buildCoreExtras(filesDir: Directory('${support.path}/files')..createSync(), supportDir: support, regionsBaseUrl: 'http://127.0.0.1:9/', placesBaseUrl: 'http://127.0.0.1:9/');
    final layersCfg = {...(extras['layers'] as Map<String, dynamic>), 'catalogue_urls': <String>[]};
    final core = await SearchCore.open(const [], extra: {'layers': layersCfg, 'regions': extras['regions']});
    final probe = _Probe();
    final policy = DataPolicy(settings: AppSettings(), probe: probe);
    final engine = CoreLayerEngine(openCore: () async => core, layersConfig: () => layersCfg, policy: policy, pollEvery: const Duration(milliseconds: 200));
    final maps = MapsState(engine: engine, settingsDirOverride: settingsDir);
    await engine.start();
    await maps.init();
    maps.setOn('basemap', true);
    final catalogue = RegionCatalogue(dir: () async => Directory('${support.path}/region-catalogue'), fetch: (u) async => throw StateError('no catalogue in the proof'));
    final regions = RegionsState(policy: policy, supportDir: () async => support, catalogue: catalogue, maps: maps);
    await regions.init();

    final kind = DataKind(
      id: 'regions',
      label: 'Regions',
      icon: Icons.map_outlined,
      shared: () => {'maps': layersDir, 'regions': regionsDir},
      notShared: {'maps': fixed ? _mapsFixed : _mapsBefore, 'regions': fixed ? _regionsFixed : _regionsBefore},
      shareLabel: 'Maps',
    );
    final sharing = SharingState(
      policy: policy,
      supportDir: () async => support,
      deviceName: name,
      kinds: [kind],
      linkShares: const [],
      opener: (cfg) async => _Real(await SyncCore.open({...cfg, 'relay': false, 'dht': false, 'mdns': false, 'lookup': false, 'interval_secs': 5, 'port': port})),
    );
    await sharing.init();

    Future<Map<String, dynamic>> syncOnce({int waitSecs = 60}) async {
      String? err;
      if (sharing.running) {
        final before = ((sharing.status['rounds'] as num?) ?? 0).toInt();
        try {
          await sharing.syncNow();
        } catch (e) {
          err = '$e';
        }
        final end = DateTime.now().add(Duration(seconds: waitSecs));
        var calm = 0;
        while (DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 700));
          await sharing.refresh();
          final s = sharing.status;
          final rounds = ((s['rounds'] as num?) ?? 0).toInt();
          final busy = s['transfer'] != null || sharing.shares.any((x) => ((x['pending_files'] as num?) ?? 0) > 0);
          if (rounds > before && !busy) {
            if (++calm >= 2) break;
          } else {
            calm = 0;
          }
        }
      }
      await regions.refresh();
      return {'sync_error': err, 'rounds': sharing.status['rounds']};
    }

    Future<Map<String, dynamic>> addRegion(String id, String regionName, List<double> bbox) async {
      final rec = RegionRecord(id: id, name: regionName, kind: kDrawnRegionKind, bbox: bbox);
      await regions.download(rec, routing: false, map: true, anyway: true);
      // until the area is whole
      final end = DateTime.now().add(const Duration(minutes: 5));
      while (DateTime.now().isBefore(end)) {
        final l = regions.regionOf(id);
        if (l != null && l.areas.isNotEmpty && l.areas.every((a) => a.phase == AreaPhase.done)) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await regions.refresh();
      }
      final l = regions.regionOf(id);
      return {'areas': [for (final a in l?.areas ?? const <DownloadedArea>[]) {'id': a.id, 'phase': a.phase.name, 'bytes': a.bytes}]};
    }

    /// What this device lists and can read.
    Future<Map<String, dynamic>> dump(List<String> tiles) async {
      await regions.refresh();
      final out = <String, dynamic>{'name': name};
      out['regions'] = [
        for (final l in regions.local) {'id': l.id, 'name': l.name, 'phase': l.phase.name, 'areas': [for (final a in l.areas) '${a.id}:${a.phase.name}'], 'error': l.error},
      ];
      out['areas'] = [for (final a in engine.allAreas) {'id': a.id, 'label': a.label, 'phase': a.phase.name}];
      final reads = <String, dynamic>{};
      final client = HttpClient();
      for (final t in tiles) {
        try {
          final req = await client.getUrl(Uri.parse(engine.tilesUrl('basemap').replaceAll('{z}/{x}/{y}', t)));
          final res = await req.close();
          final body = await utf8.decodeStream(res);
          reads[t] = {'status': res.statusCode, 'from': res.headers.value('x-cache-status'), 'body': res.statusCode == 200 ? body : null};
        } catch (e) {
          reads[t] = {'error': '$e'};
        }
      }
      client.close();
      out['tiles'] = reads;
      List<String> listing(Directory d) => [
        for (final f in d.existsSync() ? d.listSync(recursive: true, followLinks: false).whereType<File>() : const <File>[])
          '${f.path.substring(d.path.length + 1)} (${f.lengthSync()})',
      ]..sort();
      out['layers_files'] = listing(layersDir);
      out['regions_files'] = listing(regionsDir);
      out['conflict_files'] = [for (final f in [...listing(layersDir), ...listing(regionsDir)]) if (f.contains('(conflict')) f];
      return out;
    }

    Future<dynamic> run(String op, Map<String, dynamic> a) async {
      switch (op) {
        case 'ping':
          return {'pid': pid, 'fixed': fixed, 'tile_host': host.port};
        case 'sharing_setup':
          await sharing.setUp();
          return {'running': sharing.running, 'error': sharing.error, 'id': sharing.myId};
        case 'link_code':
          return {'code': await sharing.linkCode()};
        case 'link':
          final r = await sharing.link('${a['code']}');
          return {'peer': r.peer, 'name': r.name};
        case 'share_maps':
          await sharing.setShared(kind, true);
          return {'shares': sharing.shares.map((s) => s['id']).toList()};
        case 'pause':
          probe.set(ConnectionKind.none);
          await Future<void>.delayed(const Duration(seconds: 2));
          await sharing.refresh();
          return {'paused': sharing.status['paused']};
        case 'resume':
          probe.set(ConnectionKind.wifi);
          await Future<void>.delayed(const Duration(seconds: 2));
          await sharing.refresh();
          return {'paused': sharing.status['paused']};
        case 'add_region':
          return addRegion('${a['id']}', '${a['name']}', [for (final v in a['bbox'] as List) (v as num).toDouble()]);
        case 'carry_on':
          await regions.carryOn('${a['id']}', anyway: true);
          final end = DateTime.now().add(const Duration(minutes: 5));
          while (DateTime.now().isBefore(end)) {
            await regions.refresh();
            final l = regions.regionOf('${a['id']}');
            if (l != null && l.areas.isNotEmpty && l.areas.every((x) => x.phase == AreaPhase.done)) break;
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
          return {'phase': regions.regionOf('${a['id']}')?.phase.name};
        case 'delete_region':
          await regions.remove('${a['id']}');
          return {'deleted': a['id']};
        case 'synced_flag':
          // what the delete's confirmation reads (rel-1.1 after the fix only)
          return {'synced': (sharing as dynamic).mapsTakenByAnotherDevice};
        case 'sync':
          Map<String, dynamic> last = {};
          for (var i = 0; i < ((a['rounds'] as num?) ?? 1); i++) {
            last = await syncOnce();
          }
          return last;
        case 'status':
          await sharing.refresh();
          return {
            'running': sharing.running,
            'rounds': sharing.status['rounds'],
            'peers': [for (final p in sharing.peers) {'name': p['name'], 'live': p['live'], 'error': p['error']}],
            'shares': [for (final s in sharing.shares) {'id': s['id'], 'files': s['files'], 'pending_files': s['pending_files']}],
          };
        case 'dump':
          return dump([for (final t in (a['tiles'] as List? ?? const [])) '$t']);
        case 'quit':
          sharing.dispose();
          regions.dispose();
          await core.close();
          await host.close(force: true);
          return {};
      }
      throw StateError('unknown op $op');
    }

    final cmd = Directory('${root.path}/cmd')..createSync(recursive: true);
    final res = Directory('${root.path}/res')..createSync(recursive: true);
    File('${root.path}/ready.json').writeAsStringSync(jsonEncode({'pid': pid}));
    log('ready pid=$pid fixed=$fixed');
    final running = <String>{};
    while (true) {
      final files = cmd.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()..sort((a, b) => a.path.compareTo(b.path));
      var quit = false;
      for (final f in files) {
        final n = f.uri.pathSegments.last;
        if (running.contains(n) || File('${res.path}/$n').existsSync()) continue;
        String text;
        try {
          text = f.readAsStringSync();
        } on FileSystemException {
          continue;
        }
        final j = jsonDecode(text) as Map<String, dynamic>;
        running.add(n);
        log('cmd $n ${j['op']}');
        Map<String, dynamic> r;
        try {
          r = {'ok': true, 'result': await run('${j['op']}', ((j['args'] as Map?) ?? const {}).cast<String, dynamic>())};
        } catch (e, st) {
          log('error $e\n$st');
          r = {'ok': false, 'error': '$e'};
        }
        File('${res.path}/$n.tmp').writeAsStringSync(jsonEncode(r));
        File('${res.path}/$n.tmp').renameSync('${res.path}/$n');
        if (j['op'] == 'quit') quit = true;
      }
      if (quit) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  });
}
