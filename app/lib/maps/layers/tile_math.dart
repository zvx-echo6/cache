import 'dart:math' as math;

import '../geo.dart';

/// Web-mercator tile arithmetic (the z/x/y scheme every layer uses).
class TileMath {
  static const double maxLat = 85.0511287798;

  static int tileX(double lon, int z) {
    final n = 1 << z;
    return (((lon + 180) / 360) * n).floor().clamp(0, n - 1);
  }

  static int tileY(double lat, int z) {
    final n = 1 << z;
    final l = lat.clamp(-maxLat, maxLat) * math.pi / 180;
    final y = (1 - math.log(math.tan(l) + 1 / math.cos(l)) / math.pi) / 2;
    return (y * n).floor().clamp(0, n - 1);
  }

  /// The x and y ranges (inclusive) of the tiles that touch [b] at zoom [z].
  static ({int x0, int x1, int y0, int y1}) range(GeoBounds b, int z) =>
      (x0: tileX(b.west, z), x1: tileX(b.east, z), y0: tileY(b.north, z), y1: tileY(b.south, z));

  static int count(GeoBounds b, int z) {
    final r = range(b, z);
    return (r.x1 - r.x0 + 1) * (r.y1 - r.y0 + 1);
  }

  /// Tiles from zoom [minZ] to [maxZ] inclusive.
  static int countRange(GeoBounds b, int minZ, int maxZ) {
    var n = 0;
    for (var z = minZ; z <= maxZ; z++) {
      n += count(b, z);
    }
    return n;
  }

  /// Every tile of [b] from [minZ] to [maxZ] as (z, x, y).
  static Iterable<(int, int, int)> tiles(GeoBounds b, int minZ, int maxZ) sync* {
    for (var z = minZ; z <= maxZ; z++) {
      final r = range(b, z);
      for (var x = r.x0; x <= r.x1; x++) {
        for (var y = r.y0; y <= r.y1; y++) {
          yield (z, x, y);
        }
      }
    }
  }
}
