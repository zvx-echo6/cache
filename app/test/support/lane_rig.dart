import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../nav_fakes.dart';

class _NoSource implements PositionSource {
  @override
  Future<LocationPermissionState> permission() async => LocationPermissionState.granted;
  @override
  Future<LocationPermissionState> requestPermission() async => LocationPermissionState.granted;
  @override
  Future<bool> serviceEnabled() async => true;
  @override
  Future<Fix> current() async => fixAt(42.5, -113.8);
  @override
  Stream<Fix> stream() => const Stream.empty();
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

class LaneNav extends NavState {
  LaneNav(FakeBackend b, LocationService l)
      : super(
          backend: b,
          location: l,
          speaker: FakeSpeaker(),
          positionSource: FakeNavPosition(),
          fmt: const Fmt(UnitSystem.imperial),
          searchDebounce: const Duration(milliseconds: 1),
          meaningDebounce: const Duration(milliseconds: 2),
        );

  void poke() => notifyListeners();
}

const laneDestination = MapPlace(id: 'place:test:1', type: 'place', name: 'Cassia Regional Hospital', kind: 'Hospital', category: 'hospital', address: '1501 Hiland Ave, Burley, ID', lat: 42.5, lon: -113.5, distanceM: 24600, direction: 'E');

/// One lane as the router sends it: Valhalla's bits (`1 << LaneDirection.index`).
Map<String, dynamic> laneJson(Set<LaneDirection> directions, {LaneDirection? active, LaneDirection? valid}) => {
      'directions': directions.fold<int>(0, (a, d) => a | (1 << d.index)),
      if (active != null) 'active': 1 << active.index,
      if (valid != null) 'valid': 1 << valid.index,
    };

/// A guiding navigation state over the fake route, to put a progress with lanes on.
class LaneRig {
  late Directory dir;
  late LocationService location;
  late FakeBackend backend;
  late LaneNav nav;
  late Map<String, dynamic> route;

  Future<void> setUp() async {
    dir = Directory.systemTemp.createTempSync('lanes');
    location = LocationService(source: _NoSource(), settingsDirOverride: dir);
    await location.init();
    location.publish(fixAt(42.5, -113.8));
    backend = FakeBackend();
    nav = LaneNav(backend, location);
  }

  void tearDown() {
    nav.dispose();
    location.dispose();
    dir.deleteSync(recursive: true);
  }

  Future<void> guide({String mode = 'drive'}) async {
    route = fakeRouteJson(mode: mode);
    backend.onRoute = (to, m, from) async => MapRoute.fromJson(route);
    backend.onProgress = (r, lat, lon) async => MapProgress.fromJson(fakeProgressJson(route, 0.0));
    await nav.openDirections(laneDestination);
    await nav.start();
    nav.progress = null;
  }

  /// The next turn [metersBefore] ahead with [lanes] (JSON from [laneJson]; empty for none).
  void turnAhead(double metersBefore, List<Map<String, dynamic>> lanes, {String? type, String? instruction}) {
    final total = (route['distance_m'] as num).toDouble();
    final j = fakeProgressJson(route, 13 / 40 - metersBefore / total);
    final next = {...(j['next'] as Map<String, dynamic>), 'lanes': lanes, 'type': ?type, 'instruction': ?instruction};
    nav.progress = MapProgress.fromJson({...j, 'next': next});
    nav.poke();
  }
}

Widget laneHost(ThemeData theme, Widget Function() child, {double width = 390}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 700)),
        child: Scaffold(body: SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: Align(alignment: Alignment.topCenter, child: SizedBox(width: width - 24, child: child()))))),
      ),
    );
