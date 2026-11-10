import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'elevation_profile.dart';

/// A point on the route: where, and how far along.
typedef RouteSample = ({double lat, double lon, double distM});

/// Where the elevation tiles come from: the bytes of tile z/x/y (PNG or WebP, Terrarium-encoded), or null when there is none.
abstract class DemTiles {
  Future<Uint8List?> tile(int z, int x, int y);
}

/// The map's own tile server on this device (127.0.0.1): the elevation layer's downloaded tiles, and the ones viewed before.
/// Used inside the background isolate, so it carries only the address.
class LocalServerDemTiles implements DemTiles {
  LocalServerDemTiles(this.urlTemplate);

  /// `http://127.0.0.1:<port>/layers/<id>/{z}/{x}/{y}`.
  final String urlTemplate;
  HttpClient? _client;

  @override
  Future<Uint8List?> tile(int z, int x, int y) async {
    final c = _client ??= (HttpClient()..connectionTimeout = const Duration(seconds: 3));
    final url = urlTemplate.replaceAll('{z}', '$z').replaceAll('{x}', '$x').replaceAll('{y}', '$y');
    try {
      final req = await c.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final b = BytesBuilder(copy: false);
      await for (final chunk in res) {
        b.add(chunk);
      }
      return b.takeBytes();
    } catch (_) {
      return null;
    }
  }

  void close() => _client?.close(force: true);
}

/// The route walked every [stepM] metres, the first and the last point included.
List<RouteSample> resampleRoute(List<(double, double)> points, {double stepM = kProfileStepM}) {
  if (points.isEmpty) return const [];
  final out = <RouteSample>[(lat: points.first.$1, lon: points.first.$2, distM: 0)];
  var along = 0.0; // metres to the start of the current piece
  var next = stepM;
  for (var i = 1; i < points.length; i++) {
    final (lat0, lon0) = points[i - 1];
    final (lat1, lon1) = points[i];
    final len = haversineM(lat0, lon0, lat1, lon1);
    if (len <= 0) continue;
    while (next <= along + len) {
      final t = (next - along) / len;
      out.add((lat: lat0 + (lat1 - lat0) * t, lon: lon0 + (lon1 - lon0) * t, distM: next));
      next += stepM;
    }
    along += len;
  }
  if (along - out.last.distM > stepM * 0.05) out.add((lat: points.last.$1, lon: points.last.$2, distM: along));
  return out;
}

double haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371008.8;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
}

/// The heights of a decoded Terrarium tile, metres, row by row (NaN where the tile says nothing).
class DemGrid {
  DemGrid(this.size, this.heights);
  final int size;
  final Float32List heights;

  double at(int px, int py) => heights[py * size + px];

  /// Terrarium: height = R * 256 + G + B / 256 - 32768. Out-of-range values (as DESIGN-LAYERS.md: -12000..9000 m) are no data.
  static DemGrid? decode(Uint8List bytes) {
    final image = img.decodeImage(bytes);
    if (image == null || image.width != image.height) return null;
    final n = image.width;
    final out = Float32List(n * n);
    final rgb = image.getBytes(order: img.ChannelOrder.rgb);
    final channels = rgb.length ~/ (n * n);
    for (var i = 0; i < n * n; i++) {
      final o = i * channels;
      final h = rgb[o] * 256.0 + rgb[o + 1] + rgb[o + 2] / 256.0 - 32768.0;
      out[i] = (h < -12000 || h > 9000) ? double.nan : h;
    }
    return DemGrid(n, out);
  }
}

/// Reads heights at points from [tiles] at [zoom]: bilinear between the centres of the four nearest pixels, across tile edges.
/// Tiles are fetched once each. A point with any of its four pixels missing has no height (NaN).
Future<List<double>> sampleHeights(List<RouteSample> points, DemTiles tiles, {int zoom = 12}) async {
  final grids = <int, DemGrid?>{};
  final n = 1 << zoom;
  Future<DemGrid?> grid(int x, int y) async {
    if (y < 0 || y >= n) return null;
    final wx = ((x % n) + n) % n;
    final key = wx * n + y;
    if (grids.containsKey(key)) return grids[key];
    final bytes = await tiles.tile(zoom, wx, y);
    DemGrid? g;
    if (bytes != null && bytes.isNotEmpty) {
      try {
        g = DemGrid.decode(bytes);
      } catch (_) {
        g = null;
      }
    }
    return grids[key] = g;
  }

  final out = <double>[];
  for (final p in points) {
    final lat = p.lat.clamp(-85.0511287798, 85.0511287798);
    final fx = (p.lon + 180) / 360 * n;
    final l = lat * math.pi / 180;
    final fy = (1 - math.log(math.tan(l) + 1 / math.cos(l)) / math.pi) / 2 * n;
    final tx = fx.floor(), ty = fy.floor();
    final g0 = await grid(tx, ty);
    if (g0 == null) {
      out.add(double.nan);
      continue;
    }
    final size = g0.size;
    // Pixel coordinates in the world at this zoom, measured from pixel centres.
    final px = fx * size - 0.5, py = fy * size - 0.5;
    final x0 = px.floor(), y0 = py.floor();
    final ax = px - x0, ay = py - y0;
    Future<double> h(int gx, int gy) async {
      final g = await grid((gx / size).floor(), (gy / size).floor());
      if (g == null || g.size != size) return double.nan;
      return g.at(gx - (gx / size).floor() * size, gy - (gy / size).floor() * size);
    }

    final h00 = await h(x0, y0), h10 = await h(x0 + 1, y0), h01 = await h(x0, y0 + 1), h11 = await h(x0 + 1, y0 + 1);
    final top = h00 + (h10 - h00) * ax;
    final bottom = h01 + (h11 - h01) * ax;
    out.add(top + (bottom - top) * ay);
  }
  return out;
}

/// The whole job: walk the route, read the heights, and build the profile. Runs in a background isolate (see
/// [RouteElevation]); [points] are (lat, lon).
Future<ElevationProfile> buildRouteProfile(List<(double, double)> points, DemTiles tiles, {int zoom = 12, double stepM = kProfileStepM}) async {
  final samples = resampleRoute(points, stepM: stepM);
  if (samples.length < 2) return ElevationProfile.none(samples.isEmpty ? 0 : samples.last.distM);
  final heights = await sampleHeights(samples, tiles, zoom: zoom);
  return ElevationProfile.fromSamples([for (final s in samples) s.distM], heights, totalM: samples.last.distM);
}
