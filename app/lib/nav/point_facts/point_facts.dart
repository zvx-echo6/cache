import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../maps/layers/layer_def.dart';
import '../../maps/layers/layer_engine.dart';
import '../elevation/route_sampler.dart';
import 'elevation_at.dart';
import 'land_at.dart';

/// What the place card looks up for a point: its elevation and who manages the land there. Each answers null when it cannot
/// say (no data for the spot, not on the phone and no connection): the card then shows nothing for it.
class PointFacts {
  const PointFacts({required this.elevationM, required this.land});

  final Future<double?> Function(double lat, double lon) elevationM;
  final Future<LandAnswer?> Function(double lat, double lon) land;

  /// Reads from the layer engine's tile server, the way the map and the route's elevation profile do: the elevation layer
  /// (Terrarium tiles) and the public-lands layer (PAD-US vector tiles), downloaded or viewed before, or from the source when online.
  factory PointFacts.fromEngine(LayerEngine engine) {
    Future<double?> elevation(double lat, double lon) async {
      if (!engine.ready) return null;
      LayerDef? def = engine.layer('elevation');
      def ??= engine.layers.where((l) => l.kind == LayerKind.elevation).firstOrNull;
      if (def == null) return null;
      final url = engine.tilesUrl(def.id);
      if (url.contains(':0/')) return null;
      final zoom = def.maxZoom.clamp(0, 12);
      if (kIsWeb) {
        final tiles = HttpDemTiles(url);
        try {
          return await elevationAt(lat, lon, tiles, zoom: zoom);
        } finally {
          tiles.close();
        }
      }
      // The tile is decoded in a background isolate: a 512 pixel tile is too much to decode on the screen's own turn.
      return compute(_elevationInIsolate, (url, zoom, lat, lon));
    }

    Future<LandAnswer?> land(double lat, double lon) async {
      if (!engine.ready) return null;
      final def = engine.layers.where((l) => l.kind == LayerKind.vector && l.styleRole == 'public_lands').firstOrNull;
      if (def == null) return null;
      final url = engine.tilesUrl(def.id);
      if (url.contains(':0/')) return null;
      final client = http.Client();
      try {
        return await landAt(lat, lon, httpLandTiles(url, client), zoom: def.maxZoom.clamp(0, 14));
      } finally {
        client.close();
      }
    }

    return PointFacts(elevationM: elevation, land: land);
  }
}

Future<double?> _elevationInIsolate((String, int, double, double) a) async {
  final tiles = LocalServerDemTiles(a.$1);
  try {
    return await elevationAt(a.$3, a.$4, tiles, zoom: a.$2);
  } finally {
    tiles.close();
  }
}

/// Reads tiles of the public-lands layer from [urlTemplate] (`{z}`, `{x}` and `{y}` in it): 200 is the tile, 204 is "nothing mapped
/// here", anything else (503: not on this device and no connection) is no answer.
LandTileFetch httpLandTiles(String urlTemplate, http.Client client) => (z, x, y) async {
      final url = urlTemplate.replaceAll('{z}', '$z').replaceAll('{x}', '$x').replaceAll('{y}', '$y');
      try {
        final r = await client.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
        if (r.statusCode == 204) return const LandTileEmpty();
        if (r.statusCode == 200) return LandTileData(r.bodyBytes);
      } catch (_) {}
      return const LandTileUnavailable();
    };
