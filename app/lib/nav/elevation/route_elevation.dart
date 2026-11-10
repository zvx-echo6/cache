import 'dart:async';
import 'dart:isolate';

import 'package:cache_search/cache_search.dart' show MapRoute;
import 'package:flutter/foundation.dart';

import '../../maps/layers/layer_def.dart';
import '../../maps/layers/layer_engine.dart';
import 'elevation_profile.dart';
import 'route_sampler.dart';

/// Works out a route's elevation profile; tests give their own.
typedef ElevationLoader = Future<ElevationProfile> Function(MapRoute route);

/// The elevation profile of the route shown (the preview's chosen route, or the one being followed), and whether the guidance
/// card's elevation panel is pulled up. A profile is worked out once per route, in a background isolate.
class RouteElevation extends ChangeNotifier {
  RouteElevation({required this.loader});

  final ElevationLoader loader;

  String? _routeId;
  ElevationProfile? _profile;
  bool _loading = false;
  bool _open = false;

  /// The profile of the route last asked for, or null while it is worked out (or when there is no route).
  ElevationProfile? get profile => _profile;
  bool get loading => _loading;

  /// The panel on the guidance card is pulled up.
  bool get open => _open;

  /// The profile for [route] (null: none). The same route again does nothing.
  void request(MapRoute? route) {
    if (route == null) {
      if (_routeId == null) return;
      _routeId = null;
      _profile = null;
      _loading = false;
      notifyListeners();
      return;
    }
    if (route.routeId == _routeId) return;
    final id = _routeId = route.routeId;
    _profile = null;
    _loading = true;
    notifyListeners();
    unawaited(() async {
      ElevationProfile p;
      try {
        p = await loader(route);
      } catch (_) {
        p = ElevationProfile.none(route.distanceM);
      }
      if (_disposed || _routeId != id) return;
      _profile = p;
      _loading = false;
      notifyListeners();
    }());
  }

  void setOpen(bool v) {
    if (_open == v) return;
    _open = v;
    notifyListeners();
  }

  void toggle() => setOpen(!_open);

  /// Where the position is on the profile: the core's metres along the route, scaled to the profile's own length (the two
  /// measure the same line slightly differently).
  double? positionOnProfile(double? distanceAlongM, double routeM) {
    final p = _profile;
    if (p == null || distanceAlongM == null || routeM <= 0) return null;
    return (distanceAlongM * p.totalM / routeM).clamp(0, p.totalM).toDouble();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The real loader: the map's elevation layer through the layer engine's tile server (its downloaded tiles and the ones viewed
/// before), sampled and smoothed in a background isolate.
ElevationLoader tileServerElevationLoader(LayerEngine engine) => (route) async {
      final total = route.distanceM;
      if (!engine.ready) return ElevationProfile.none(total);
      LayerDef? def = engine.layer('elevation');
      def ??= engine.layers.where((l) => l.kind == LayerKind.elevation).firstOrNull;
      if (def == null) return ElevationProfile.none(total);
      final url = engine.tilesUrl(def.id);
      if (url.contains(':0/')) return ElevationProfile.none(total);
      final zoom = def.maxZoom.clamp(0, 12);
      final points = [for (final p in route.points) (p.lat, p.lon)];
      return profileInIsolate(url, zoom, points);
    };

/// Runs the sampling in a background isolate. A top-level function, so the closure carries only the address, the zoom and the
/// points.
Future<ElevationProfile> profileInIsolate(String urlTemplate, int zoom, List<(double, double)> points) => Isolate.run(() async {
      final tiles = LocalServerDemTiles(urlTemplate);
      try {
        return await buildRouteProfile(points, tiles, zoom: zoom);
      } finally {
        tiles.close();
      }
    });
