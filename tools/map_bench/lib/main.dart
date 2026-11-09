// The route mini map's costs on an Android emulator (.github/workflows/map-bench.yml): one live map following a simulated drive, and
// the whole-route picture made by the app's own snapshotter (RouteSnapshot.kt, copied in by the workflow) with the position dot
// drawn over it by the app's distance rule. It prints one "BENCH {json}" line per measurement and "BENCH DONE" at the end.
//
// Measured:
//  - snapshot: the native render time (style, tiles, drawing) and the round trip with decoding, for the corner picture and the
//    full-screen one, first (cold tiles) and again (warm);
//  - memory: the process's PSS and its graphics share, and the picture's own pixel bytes;
//  - frames and CPU, for 30 s each: the live map alone; the live map with the corner picture and the dot (distance rule); the same
//    with the dot drawn every frame (the overlay's upper bound); and swapped (the full picture with the live map in the corner).
//
// The map style is OpenFreeMap's (the app's base map source), read over the network; the app reads the same tiles from its own tile
// server on the phone, so the warm numbers are the closer ones.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'overview_camera.dart';

const _styleUrl = 'https://tiles.openfreemap.org/styles/liberty';
const _snap = MethodChannel('co.cache/route_snapshot');
const _stats = MethodChannel('co.cache.bench/stats');

/// A drive through Twin Falls, Idaho (about 9 km), as (lat, lon).
const _route = [
  (42.5629, -114.4609), (42.5629, -114.4400), (42.5700, -114.4400), (42.5700, -114.4200), (42.5800, -114.4150),
  (42.5850, -114.4050), (42.5944, -114.4003),
];

void _log(String what, Map<String, Object?> data) {
  // ignore: avoid_print
  print('BENCH ${jsonEncode({'what': what, ...data})}');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: Bench()));
}

enum Mode { liveOnly, insetRule, insetEveryFrame, swapped }

class Bench extends StatefulWidget {
  const Bench({super.key});
  @override
  State<Bench> createState() => _BenchState();
}

class _BenchState extends State<Bench> with SingleTickerProviderStateMixin {
  MapLibreMapController? _map;
  String? _style;
  Mode _mode = Mode.liveOnly;
  ui.Image? _inset;
  OverviewCamera? _insetCam;
  ui.Image? _full;
  OverviewCamera? _fullCam;
  final _pos = ValueNotifier<({double lat, double lon, double heading})>((lat: _route.first.$1, lon: _route.first.$2, heading: 90));
  final _dot = ValueNotifier<Offset?>(null);
  final _gate = RedrawGate();
  int _dotDraws = 0;
  late final Ticker _ticker = createTicker((_) {
    if (_mode == Mode.insetEveryFrame) _placeDot(force: true);
  });

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Future<Map<String, Object?>> _readStats() async => (await _stats.invokeMapMethod<String, Object?>('read'))!;

  /// The simulated drive: the position moves along the route at [speed] m/s, a fix a second, and the live map follows it.
  Timer _drive(double speed) {
    var along = 0.0;
    final legs = <double>[];
    for (var i = 1; i < _route.length; i++) {
      legs.add(_metres(_route[i - 1], _route[i]));
    }
    return Timer.periodic(const Duration(seconds: 1), (_) {
      along = (along + speed) % legs.fold<double>(0, (a, b) => a + b);
      var rest = along;
      for (var i = 0; i < legs.length; i++) {
        if (rest <= legs[i]) {
          final t = rest / legs[i];
          final a = _route[i], b = _route[i + 1];
          final lat = a.$1 + (b.$1 - a.$1) * t, lon = a.$2 + (b.$2 - a.$2) * t;
          final heading = (math.atan2((b.$2 - a.$2) * math.cos(lat * math.pi / 180), b.$1 - a.$1) * 180 / math.pi + 360) % 360;
          _pos.value = (lat: lat, lon: lon, heading: heading);
          _map?.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: LatLng(lat, lon), zoom: 16, bearing: heading)), duration: const Duration(milliseconds: 900));
          if (_mode == Mode.insetRule || _mode == Mode.swapped) _placeDot();
          return;
        }
        rest -= legs[i];
      }
    });
  }

  void _placeDot({bool force = false}) {
    final cam = _mode == Mode.swapped ? _fullCam : _insetCam;
    if (cam == null) return;
    final p = _pos.value;
    final at = cam.project(p.lat, p.lon);
    if (!force) {
      final due = _gate.decide(at, p.heading, DateTime.now());
      if (due != Duration.zero) return; // the bench drives at 1 fix/s, so a wait never applies
      _gate.drawn(at, p.heading, DateTime.now());
    }
    _dotDraws++;
    _dot.value = force ? at + Offset(0, (_dotDraws % 2) * 0.01) : at;
  }

  Future<(ui.Image, double, double)> _render(OverviewCamera cam, double ratio) async {
    final watch = Stopwatch()..start();
    final r = (await _snap.invokeMapMethod<String, Object?>('render', {
      'style': _routeStyle(_style!),
      'lat': cam.lat,
      'lon': cam.lon,
      'zoom': cam.zoom,
      'width': cam.size.width.round(),
      'height': cam.size.height.round(),
      'pixelRatio': ratio,
    }))!;
    final rgba = r['rgba']! as Uint8List;
    final w = (r['width']! as num).toInt(), h = (r['height']! as num).toInt();
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    final image = await c.future;
    return (image, (r['ms']! as num).toDouble(), watch.elapsedMicroseconds / 1000);
  }

  String _routeStyle(String style) {
    final s = jsonDecode(style) as Map<String, dynamic>;
    (s['sources'] as Map)['route'] = {
      'type': 'geojson',
      'data': {
        'type': 'Feature',
        'geometry': {
          'type': 'LineString',
          'coordinates': [for (final p in _route) [p.$2, p.$1]],
        },
        'properties': <String, Object>{},
      },
    };
    (s['layers'] as List).addAll([
      {'id': 'route-casing', 'type': 'line', 'source': 'route', 'layout': {'line-cap': 'round', 'line-join': 'round'}, 'paint': {'line-color': '#ffffff', 'line-width': 10}},
      {'id': 'route', 'type': 'line', 'source': 'route', 'layout': {'line-cap': 'round', 'line-join': 'round'}, 'paint': {'line-color': '#1f6fa8', 'line-width': 6}},
    ]);
    return jsonEncode(s);
  }

  /// [seconds] of frames, CPU and memory in the current mode.
  Future<void> _measure(String name, {int seconds = 30}) async {
    final timings = <FrameTiming>[];
    void collect(List<FrameTiming> t) => timings.addAll(t);
    await Future<void>.delayed(const Duration(seconds: 8)); // settle (tiles, first frames)
    final before = await _readStats();
    final draws = _dotDraws;
    SchedulerBinding.instance.addTimingsCallback(collect);
    final wall = Stopwatch()..start();
    await Future<void>.delayed(Duration(seconds: seconds));
    SchedulerBinding.instance.removeTimingsCallback(collect);
    final after = await _readStats();
    final ms = wall.elapsedMilliseconds;
    double pct(List<double> xs, double p) {
      if (xs.isEmpty) return 0;
      xs.sort();
      return xs[math.min(xs.length - 1, (xs.length * p).floor())];
    }

    final build = [for (final t in timings) t.buildDuration.inMicroseconds / 1000.0];
    final raster = [for (final t in timings) t.rasterDuration.inMicroseconds / 1000.0];
    final cpu = ((after['cpuMs']! as num) - (before['cpuMs']! as num)).toDouble();
    _log('mode', {
      'mode': name,
      'seconds': ms / 1000,
      'flutterFrames': timings.length,
      'fps': timings.length / (ms / 1000),
      'buildP50': pct(build, 0.5),
      'buildP90': pct(build, 0.9),
      'rasterP50': pct(raster, 0.5),
      'rasterP90': pct(raster, 0.9),
      'rasterP99': pct(raster, 0.99),
      'cpuPercentOfOneCore': cpu / ms * 100,
      'dotDraws': _dotDraws - draws,
      'pssKb': after['pssKb'],
      'graphicsKb': after['graphicsKb'],
      'nativeHeapKb': after['nativeHeapKb'],
    });
  }

  Future<void> _run() async {
    try {
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(_styleUrl));
      final res = await req.close();
      _style = await res.transform(utf8.decoder).join();
      client.close();
      setState(() {});
      while (_map == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final size = MediaQuery.sizeOf(context);
      final ratio = MediaQuery.devicePixelRatioOf(context);
      _log('device', {'logicalWidth': size.width, 'logicalHeight': size.height, 'pixelRatio': ratio});
      var lat0 = 90.0, lat1 = -90.0, lon0 = 180.0, lon1 = -180.0;
      for (final (la, lo) in _route) {
        lat0 = math.min(lat0, la);
        lat1 = math.max(lat1, la);
        lon0 = math.min(lon0, lo);
        lon1 = math.max(lon1, lo);
      }
      _insetCam = OverviewCamera.fit(south: lat0, west: lon0, north: lat1, east: lon1, size: const Size(108, 108), padding: const EdgeInsets.fromLTRB(14, 16, 14, 16));
      _fullCam = OverviewCamera.fit(south: lat0, west: lon0, north: lat1, east: lon1, size: size, padding: const EdgeInsets.fromLTRB(32, 150, 32, 210));

      final s0 = await _readStats();
      for (final (name, cam) in [('inset-cold', _insetCam!), ('inset-warm', _insetCam!), ('inset-warm', _insetCam!), ('full-cold', _fullCam!), ('full-warm', _fullCam!), ('full-warm', _fullCam!)]) {
        final (image, nativeMs, roundTripMs) = await _render(cam, ratio);
        _log('snapshot', {'picture': name, 'widthPx': image.width, 'heightPx': image.height, 'pixelBytes': image.width * image.height * 4, 'nativeMs': nativeMs, 'roundTripMs': roundTripMs});
        if (name.startsWith('inset')) {
          _inset?.dispose();
          _inset = image;
        } else {
          _full?.dispose();
          _full = image;
        }
      }
      final s1 = await _readStats();
      _log('snapshotMemory', {'pssKbBefore': s0['pssKb'], 'pssKbAfter': s1['pssKb'], 'graphicsKbBefore': s0['graphicsKb'], 'graphicsKbAfter': s1['graphicsKb']});

      for (final (mode, speed) in [(Mode.liveOnly, 30.0), (Mode.insetRule, 30.0), (Mode.insetRule, 1.4), (Mode.insetEveryFrame, 30.0), (Mode.swapped, 30.0)]) {
        setState(() => _mode = mode);
        _gate.reset();
        if (mode == Mode.insetEveryFrame) {
          _ticker.start();
        } else if (_ticker.isActive) {
          _ticker.stop();
        }
        final drive = _drive(speed);
        await _measure('${mode.name}@${speed}mps');
        drive.cancel();
      }
    } catch (e, st) {
      _log('error', {'error': '$e', 'stack': '$st'});
    }
    // ignore: avoid_print
    print('BENCH DONE');
  }

  @override
  Widget build(BuildContext context) {
    final style = _style;
    if (style == null) return const ColoredBox(color: Colors.white);
    final swapped = _mode == Mode.swapped;
    final showInset = _mode != Mode.liveOnly;
    final screen = MediaQuery.sizeOf(context);
    const side = 112.0;
    final corner = Rect.fromLTWH(screen.width - 12 - side + 2, screen.height - 140 - side + 2, side - 4, side - 4);
    return Stack(
      children: [
        if (swapped) Positioned.fill(key: const ValueKey('full'), child: _picture(_full, 1.6)),
        Positioned(
          key: const ValueKey('live'),
          left: swapped ? corner.left : 0,
          top: swapped ? corner.top : 0,
          right: swapped ? null : 0,
          bottom: swapped ? null : 0,
          width: swapped ? corner.width : null,
          height: swapped ? corner.height : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(swapped ? 16 : 0),
            clipBehavior: swapped ? Clip.antiAlias : Clip.none,
            child: MapLibreMap(
              styleString: style,
              initialCameraPosition: CameraPosition(target: LatLng(_route.first.$1, _route.first.$2), zoom: 16),
              onMapCreated: (c) {
                _map = c;
                c.forceOnlineMode();
              },
              compassEnabled: false,
              tiltGesturesEnabled: false,
              logoEnabled: false,
              myLocationEnabled: false,
            ),
          ),
        ),
        if (showInset && !swapped)
          Positioned(left: corner.left, top: corner.top, width: corner.width, height: corner.height, child: ClipRRect(borderRadius: BorderRadius.circular(16), child: _picture(_inset, 1))),
      ],
    );
  }

  Widget _picture(ui.Image? image, double dotScale) => Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFFF8F4F0)),
          if (image != null) RawImage(image: image, fit: BoxFit.cover),
          RepaintBoundary(
            child: ValueListenableBuilder<Offset?>(
              valueListenable: _dot,
              builder: (context, at, _) => CustomPaint(painter: _DotPainter(at, dotScale)),
            ),
          ),
        ],
      );
}

class _DotPainter extends CustomPainter {
  _DotPainter(this.at, this.scale);
  final Offset? at;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final p = at;
    if (p == null) return;
    canvas.drawCircle(p, 11 * scale, Paint()..color = const Color(0x2E1F6FA8));
    canvas.drawCircle(p, 7 * scale, Paint()..color = const Color(0xF2FFFFFF));
    canvas.drawCircle(p, 4.5 * scale, Paint()..color = const Color(0xFF1F6FA8));
  }

  @override
  bool shouldRepaint(_DotPainter old) => old.at != at || old.scale != scale;
}

double _metres((double, double) a, (double, double) b) {
  const r = 6371008.8;
  final dLat = (b.$1 - a.$1) * math.pi / 180, dLon = (b.$2 - a.$2) * math.pi / 180;
  final h = math.pow(math.sin(dLat / 2), 2) + math.cos(a.$1 * math.pi / 180) * math.cos(b.$1 * math.pi / 180) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}
