import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cache_search/cache_search.dart' show MapRoute;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../maps/palette/map_palette.dart';
import '../../maps/style/style_generator.dart';
import '../nav_geojson.dart';
import 'overview_camera.dart';

/// One rendered whole-route picture: RGBA pixels and how long the offscreen render took on the device.
class OverviewPicture {
  const OverviewPicture({required this.image, required this.camera, required this.pixelRatio, required this.renderMs});

  final ui.Image image;
  final OverviewCamera camera;
  final double pixelRatio;

  /// The native render alone (style, tiles and drawing), milliseconds.
  final double renderMs;

  int get bytes => image.width * image.height * 4;
}

/// Renders the whole-route picture: the real base map, offscreen, once per route, size and theme. The app's own native code does
/// it (RouteSnapshot.kt, AppDelegate.swift) with MapLibre's map snapshotter on the same style and tile server as the live map;
/// the live map itself is never touched. Tests give their own.
abstract class RouteSnapshotter {
  /// The picture of [styleJson] seen by [camera] at [pixelRatio], or null when it could not be made.
  Future<OverviewPicture?> render({required String styleJson, required OverviewCamera camera, required double pixelRatio});
}

/// The native snapshotter, over the `co.cache/route_snapshot` channel.
class ChannelRouteSnapshotter implements RouteSnapshotter {
  const ChannelRouteSnapshotter();

  static const channel = MethodChannel('co.cache/route_snapshot');

  @override
  Future<OverviewPicture?> render({required String styleJson, required OverviewCamera camera, required double pixelRatio}) async {
    try {
      final r = await channel.invokeMapMethod<String, dynamic>('render', {
        'style': styleJson,
        'lat': camera.lat,
        'lon': camera.lon,
        'zoom': camera.zoom,
        'width': camera.size.width.round(),
        'height': camera.size.height.round(),
        'pixelRatio': pixelRatio,
      });
      if (r == null) return null;
      final rgba = r['rgba'] as Uint8List;
      final w = (r['width'] as num).toInt(), h = (r['height'] as num).toInt();
      final image = await _decode(rgba, w, h);
      return OverviewPicture(image: image, camera: camera, pixelRatio: pixelRatio, renderMs: (r['ms'] as num?)?.toDouble() ?? 0);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<ui.Image> _decode(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }
}

/// The map style for the picture: the live map's style with the route and the destination written into it (the live map adds
/// them at run time, which a snapshot does not see), and no position (the dot is drawn over the picture).
String overviewStyleJson(String styleJson, MapRoute route) {
  final style = jsonDecode(styleJson) as Map<String, dynamic>;
  final sources = (style['sources'] as Map).cast<String, dynamic>();
  final end = route.destination;
  sources[kRouteSource] = {'type': 'geojson', 'data': routeGeoJson([route], 0)};
  sources[kPinSource] = {
    'type': 'geojson',
    'data': {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'geometry': {'type': 'Point', 'coordinates': [end.lon, end.lat]},
          'properties': {'role': 'selected', 'id': 'destination'},
        },
      ],
    },
  };
  // Where it starts: a small ring.
  final start = route.points.isEmpty ? null : route.points.first;
  if (start != null) {
    sources['cache-overview-start'] = {
      'type': 'geojson',
      'data': {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [start.lon, start.lat]},
        'properties': <String, dynamic>{},
      },
    };
    final layers = (style['layers'] as List).cast<Map<String, dynamic>>().toList();
    final routeAt = layers.indexWhere((l) => l['id'] == kRouteRoad);
    final casing = layers.where((l) => l['id'] == kRouteCasing).firstOrNull;
    final road = layers.where((l) => l['id'] == kRouteRoad).firstOrNull;
    final ring = {
      'id': 'cache-overview-start',
      'type': 'circle',
      'source': 'cache-overview-start',
      'paint': {
        'circle-radius': 5,
        'circle-color': ((casing?['paint'] as Map?)?['line-color']) ?? '#ffffff',
        'circle-stroke-width': 3,
        'circle-stroke-color': ((road?['paint'] as Map?)?['line-color']) ?? '#1f6fa8',
      },
    };
    layers.insert(routeAt < 0 ? layers.length : routeAt + 1, ring);
    style['layers'] = layers;
  }
  sources[kPositionSource] = {'type': 'geojson', 'data': {'type': 'FeatureCollection', 'features': <Object>[]}};
  style['sources'] = sources;
  return jsonEncode(style);
}

/// The position on the whole-route picture: a halo, a ring and an arrow turned to the heading (or a dot without one).
class PositionDotPainter extends CustomPainter {
  PositionDotPainter({required this.at, required this.heading, required this.palette, this.scale = 1});

  final Offset? at;
  final double? heading;
  final MapPalette palette;

  /// 1 on the corner picture, bigger on the full-screen one.
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final p = at;
    if (p == null) return;
    final s = 7.0 * scale;
    canvas.drawCircle(p, s * 1.6, Paint()..color = palette['position'].withValues(alpha: 0.18));
    canvas.drawCircle(p, s, Paint()..color = palette['positionRing'].withValues(alpha: 0.95));
    final h = heading;
    if (h == null) {
      canvas.drawCircle(p, s * 0.62, Paint()..color = palette['position']);
      return;
    }
    canvas.save();
    canvas.translate(p.dx, p.dy);
    canvas.rotate(h * math.pi / 180);
    // Material's navigation arrow, centred and sized to the ring.
    final k = s * 1.5 / 24;
    canvas.scale(k);
    canvas.translate(-12, -12);
    final arrow = Path()
      ..moveTo(12, 2)
      ..lineTo(4.5, 20.29)
      ..lineTo(5.21, 21)
      ..lineTo(12, 18)
      ..lineTo(18.79, 21)
      ..lineTo(19.5, 20.29)
      ..close();
    canvas.drawPath(arrow, Paint()..color = palette['position']);
    canvas.restore();
  }

  @override
  bool shouldRepaint(PositionDotPainter old) => old.at != at || old.heading != heading || old.scale != scale || old.palette != palette;
}

/// The whole-route picture with the position dot over it. The picture is drawn once; only the dot moves, by the distance rule
/// ([RedrawGate]): when it has moved about two pixels at this picture's scale or the heading turned, at most twice a second.
class RouteOverview extends StatefulWidget {
  const RouteOverview({super.key, required this.picture, required this.palette, required this.position, this.dotScale = 1, this.clock, this.onDotDrawn});

  /// The rendered picture; null while it is made (the land colour shows, with the dot).
  final OverviewPicture? picture;
  final MapPalette palette;

  /// The phone's position and heading (lat, lon, heading).
  final ValueListenable<({double lat, double lon, double? heading})?> position;
  final double dotScale;

  @visibleForTesting
  final DateTime Function()? clock;

  /// Called each time the dot is drawn again (tests count them).
  @visibleForTesting
  final VoidCallback? onDotDrawn;

  @override
  State<RouteOverview> createState() => _RouteOverviewState();
}

class _RouteOverviewState extends State<RouteOverview> {
  final RedrawGate _gate = RedrawGate();
  final ValueNotifier<(Offset, double?)?> _dot = ValueNotifier(null);
  Timer? _wait;
  OverviewCamera? _camera;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    widget.position.addListener(_onPosition);
  }

  @override
  void didUpdateWidget(RouteOverview old) {
    super.didUpdateWidget(old);
    if (old.position != widget.position) {
      old.position.removeListener(_onPosition);
      widget.position.addListener(_onPosition);
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPosition);
    _wait?.cancel();
    _dot.dispose();
    super.dispose();
  }

  void _onPosition() {
    final cam = _camera;
    final pos = widget.position.value;
    if (cam == null || pos == null) return;
    final at = cam.project(pos.lat, pos.lon);
    final due = _gate.decide(at, pos.heading, _now());
    if (due == null) return;
    if (due == Duration.zero) {
      _wait?.cancel();
      _wait = null;
      _draw(at, pos.heading);
    } else {
      // Too soon: draw the newest position when the wait is over.
      _wait ??= Timer(due, () {
        _wait = null;
        final p = widget.position.value;
        final c = _camera;
        if (!mounted || p == null || c == null) return;
        final a = c.project(p.lat, p.lon);
        if (_gate.differs(a, p.heading)) _draw(a, p.heading);
      });
    }
  }

  void _draw(Offset at, double? heading) {
    _gate.drawn(at, heading, _now());
    _dot.value = (at, heading);
    widget.onDotDrawn?.call();
  }

  @override
  Widget build(BuildContext context) {
    final pic = widget.picture;
    return LayoutBuilder(builder: (context, box) {
      final size = box.biggest;
      // The dot is placed on the picture's own camera, scaled to the size it is shown at.
      final cam = pic?.camera;
      // The picture covers the box (BoxFit.cover, centred), so it is scaled by the larger of the two ratios.
      final cover = cam == null ? 1.0 : math.max(size.width / cam.size.width, size.height / cam.size.height);
      final shown = cam == null || size.isEmpty ? null : OverviewCamera(lat: cam.lat, lon: cam.lon, zoom: cam.zoom + math.log(cover) / math.ln2, size: size);
      if (shown != _camera) {
        _camera = shown;
        _gate.reset();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _onPosition();
        });
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: widget.palette['land']),
          if (pic != null) RawImage(image: pic.image, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
          RepaintBoundary(
            child: ValueListenableBuilder<(Offset, double?)?>(
              valueListenable: _dot,
              builder: (context, d, _) => CustomPaint(
                painter: PositionDotPainter(at: d?.$1, heading: d?.$2, palette: widget.palette, scale: widget.dotScale),
              ),
            ),
          ),
        ],
      );
    });
  }
}
