import '../elevation/route_sampler.dart';

/// The elevation at one point, metres, from the elevation layer's Terrarium tiles at [zoom] (bilinear between the four nearest
/// pixels, as the route's elevation profile reads it). Null where the tiles have no height for the point: never a guess.
Future<double?> elevationAt(double lat, double lon, DemTiles tiles, {int zoom = 12}) async {
  final h = await sampleHeights([(lat: lat, lon: lon, distM: 0)], tiles, zoom: zoom);
  final v = h.isEmpty ? double.nan : h.first;
  return v.isNaN || v.isInfinite ? null : v;
}
