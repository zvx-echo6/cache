// The directions card when the road data for a trip is not on the device yet (code no_road_data), at phone width 390, in the four
// themes. The words are the app's own routeErrorText for that code.
// flutter test test_shots/route_no_road_data_renders_test.dart --update-goldens  (pictures in test_shots/route_no_road_data/)

import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/ui/route_panel.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/nav_fakes.dart';
import 'shot_kit.dart';

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

class _Nav extends NavState {
  _Nav(FakeBackend b, LocationService l)
      : super(
          backend: b,
          location: l,
          speaker: FakeSpeaker(),
          positionSource: FakeNavPosition(),
          fmt: const Fmt(UnitSystem.imperial),
        );
  void poke() => notifyListeners();
}

void main() {
  setUpAll(loadShotFonts);

  for (final theme in CacheThemeId.values) {
    testWidgets('no road data, phone-390, ${theme.name}', (tester) async {
      final dir = Directory.systemTemp.createTempSync('route-nrd-shot-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final location = LocationService(source: _NoSource(), settingsDirOverride: dir);
      await tester.runAsync(location.init);
      location.publish(fixAt(42.5, -113.8));
      final nav = _Nav(FakeBackend(), location);
      addTearDown(() {
        nav.dispose();
        location.dispose();
      });
      nav.routeError = NavState.routeErrorText(MapRoute.fromJson({
        'ok': false, 'route_id': 'x', 'mode': 'drive',
        'errors': [{'code': 'no_road_data', 'message': 'No path could be found for input', 'end': 'from'}],
      }));
      phone(tester, size: const Size(390, 844), ratio: 3);
      await tester.pumpWidget(shotApp(
        ListenableBuilder(
          listenable: nav,
          builder: (_, _) => Scaffold(body: SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: Align(alignment: Alignment.bottomCenter, child: RoutePanel(nav: nav, fmt: const Fmt(UnitSystem.imperial)))))),
        ),
        theme: theme,
      ));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(find.text("Road data for this trip isn't on this device yet. Connect and try again."), findsOneWidget);
      await snap(tester, 'route_no_road_data', 'phone-390-${theme.name}');
    });
  }
}
