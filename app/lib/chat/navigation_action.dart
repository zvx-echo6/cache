import 'dart:convert';

import 'package:cache_search/cache_search.dart';

/// App-only data. Never include this object in a model message or citation.
class NavigationAction {
  NavigationAction({required this.address, MapRoute? route})
    : route = usable(address, route)
          ? MapRoute.fromJson(
              (jsonDecode(jsonEncode(route!.raw)) as Map)
                  .cast<String, dynamic>(),
            )
          : null;

  final String address;
  final MapRoute? route;

  static bool usable(String address, MapRoute? route) {
    if (!address.startsWith('nav:') ||
        address.length == 4 ||
        route == null ||
        !route.ok ||
        route.routeId != address.substring(4)) {
      return false;
    }
    try {
      bool point(dynamic lat, dynamic lon) =>
          lat is num &&
          lon is num &&
          lat.isFinite &&
          lon.isFinite &&
          lat >= -90 &&
          lat <= 90 &&
          lon >= -180 &&
          lon <= 180;
      return const {
            'drive',
            'walk',
            'bike',
            'offroad_vehicle',
            'offroad_foot',
          }.contains(route.mode) &&
          route.distanceM.isFinite &&
          route.distanceM >= 0 &&
          route.durationS >= 0 &&
          route.geometry.isNotEmpty &&
          route.points.length >= 2 &&
          route.points.every((p) => point(p.lat, p.lon)) &&
          point(route.from['lat'], route.from['lon']) &&
          point(route.to['lat'], route.to['lon']);
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> toJson() => {'address': address, 'route': route?.raw};

  static NavigationAction? fromJson(dynamic value) {
    if (value is! Map || value['address'] is! String) return null;
    final address = value['address'] as String;
    if (!address.startsWith('nav:') || address.length == 4) return null;
    MapRoute? route;
    try {
      if (value['route'] is Map) {
        route = MapRoute.fromJson(
          (value['route'] as Map).cast<String, dynamic>(),
        );
      }
    } catch (_) {
      // A damaged/old snapshot must not hide the ordinary answer.
    }
    return NavigationAction(address: address, route: route);
  }

  static List<NavigationAction> decode(String json) {
    try {
      final values = jsonDecode(json);
      if (values is! List) return const [];
      return [for (final value in values) ?fromJson(value)];
    } catch (_) {
      return const [];
    }
  }
}
