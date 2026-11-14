// Guidance on the phone with no car, heading up: where the camera puts the phone's position on the map, before this fix (the
// release's camera on Android: the route preview's fit left its padding on the map, so the position sat in the middle of the
// preview's free rectangle, shifted down by the guidance offset) and after it (centred across the free map, 72% of the way down
// from the banner to the guidance bar, whatever is in the corners). On phones 390 and 320 points wide, the Galaxy S22 at its two
// display sizes (360 and 384 wide) and the Pixel 8 (412), each in the Dark and the Light theme, with the app's tab bar under the
// map as on the phone.
// The map itself is a platform view and is not drawn; the round marker is where the camera puts the position (worked out from the
// camera the screen gave the map, and for "before" from the release's sums with the padding the preview's fit left). The route and
// places are made up.
// flutter test test_shots/phone_guidance_camera_renders_test.dart --update-goldens  (pictures in test_shots/phone_guidance_camera/)

import 'dart:io';
import 'dart:math' as math;

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../test/guidance_camera_test.dart' show lastCamera, seenAt;
import '../test/location_service_test.dart' show FakeSource;
import '../test/nav_fakes.dart';
import '../test/navigation_camera_test.dart' show CameraController, NoSurface;
import '../test/support/guide_anchor.dart';
import '../test/support/test_layer_engine.dart';
import 'shot_kit.dart';

const _out = 'phone_guidance_camera';

class _Marker extends StatelessWidget {
  const _Marker(this.at);
  final ValueNotifier<Offset?> at;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ValueListenableBuilder<Offset?>(
          valueListenable: at,
          builder: (context, p, _) => Stack(
            children: [
              if (p != null)
                Positioned(
                  left: p.dx - 12,
                  top: p.dy - 12,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFFE8711A), border: Border.all(color: Colors.white, width: 3)),
                  ),
                ),
            ],
          ),
        ),
      );
}

/// The release's anchor (before this fix): 72% of the way down the whole map, kept 190 points above its foot, centred across.
Offset _releaseAnchor(Size map) {
  final y = (map.height * 0.72).clamp(map.height / 2, math.max(map.height / 2, map.height - 190)).toDouble();
  return Offset(map.width / 2, y);
}

/// Where the map package keeps the paddings of a fit, read from its own encoding of a known one (left 11, top 12, right 13,
/// bottom 14).
final List<dynamic> _fitProbe =
    CameraUpdate.newLatLngBounds(LatLngBounds(southwest: const LatLng(0, 0), northeast: const LatLng(1, 1)), left: 11, top: 12, right: 13, bottom: 14).toJson() as List<dynamic>;

const _to = MapPlace(id: 'place:test:1', type: 'place', name: 'Place 1', kind: '', address: '', lat: 42.5, lon: -113.5, matched: 'name');

Future<void> _draw(WidgetTester tester, {required String name, required Size size, required double ratio, required EdgeInsets insets, required CacheThemeId theme}) async {
  phone(tester, size: size, ratio: ratio);
  rootBundle.clear();
  final dir = Directory.systemTemp.createTempSync('guidance-camera-renders-');
  final originalPlatform = MapLibrePlatform.createInstance;
  MapLibrePlatform.createInstance = () => NoSurface();
  final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
  final engine = TestLayerEngine();
  final maps = MapsState(engine: engine, settingsDirOverride: dir);
  final route = fakeRouteJson(name: 'Place 1');
  final backend = FakeBackend()
    ..onRoute = ((to, mode, from) async => MapRoute.fromJson(route))
    ..onProgress = ((r, lat, lon) async => MapProgress.fromJson(fakeProgressJson(route, 0.2)));
  final gps = FakeNavPosition();
  final nav = NavState(backend: backend, location: location, speaker: FakeSpeaker(), positionSource: gps, fmt: const Fmt(UnitSystem.imperial), onFollow: maps.setFollow);
  final camera = CameraController();
  final before = ValueNotifier<Offset?>(null), after = ValueNotifier<Offset?>(null);
  final which = ValueNotifier<bool>(false);
  try {
    await tester.runAsync(() async {
      await location.init();
      await engine.start();
    });
    await tester.pumpWidget(shotApp(
      Scaffold(
        body: Stack(children: [
          Positioned.fill(
            child: MapsScreen(location: location, maps: maps, nav: nav, themeId: theme, glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf'),
          ),
          Positioned.fill(
            child: ValueListenableBuilder<bool>(valueListenable: which, builder: (context, isAfter, _) => _Marker(isAfter ? after : before)),
          ),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: 2,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.book_outlined), label: 'Notebooks'),
            NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Maps'),
            NavigationDestination(icon: Icon(Icons.local_library_outlined), label: 'Library'),
            NavigationDestination(icon: Icon(Icons.apps_outlined), label: 'Modules'),
          ],
        ),
      ),
      theme: theme,
      insets: insets,
    ));
    for (var i = 0; i < 600 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(camera);
    map.onStyleLoadedCallback!();
    await tester.pump();
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 160));
      }
    }

    // The route shown before Start (fitted into the preview's free rectangle), then guidance along it.
    location.publish(fixAt(42.5, -113.8, heading: 90));
    await tester.runAsync(() => nav.openDirections(_to));
    await settle();
    await tester.runAsync(() async {
      await nav.start();
      gps.controller.add(fixAt(42.5, -113.79, heading: 90));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    location.publish(fixAt(42.5, -113.79, heading: 90));
    await settle();
    location.publish(fixAt(42.5, -113.79, heading: 90));
    await settle();
    expect(maps.follow, FollowMode.headingUp);
    final mapSize = tester.getSize(find.byType(MapLibreMap));

    // After: where the camera the screen gave the map puts the position; it is the anchor the layout asks for.
    after.value = seenAt(lastCamera(camera), 42.5, -113.79, mapSize);
    expect((after.value! - GuideLayout.read(tester, safe: insets).anchor).distance, lessThan(0.5));
    expect(camera.padding, EdgeInsets.zero);

    // Before: the release's anchor, moved by the padding the preview's fit left on the map (the middle of the padded map is
    // where the release's centre landed).
    final fit = camera.cameras.cast<List<dynamic>>().lastWhere((u) => u.first == 'newLatLngBounds');
    double pad(double probe) => (fit[_fitProbe.indexOf(probe)] as num).toDouble();
    final shift = Offset((pad(11) - pad(13)) / 2, (pad(12) - pad(14)) / 2);
    before.value = _releaseAnchor(mapSize) + shift;

    final t = theme == CacheThemeId.light ? 'light' : 'dark';
    which.value = false;
    await tester.pump();
    await snap(tester, _out, '$name-$t-before');
    which.value = true;
    await tester.pump();
    await snap(tester, _out, '$name-$t-after');
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    MapLibrePlatform.createInstance = originalPlatform;
    before.dispose();
    after.dispose();
    which.dispose();
    camera.dispose();
    nav.dispose();
    maps.dispose();
    location.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  }
}

void main() {
  setUpAll(loadShotFonts);

  final List<({String name, Size size, double ratio, EdgeInsets insets})> screens = [
    (name: 'phone-390', size: const Size(390, 844), ratio: 3.0, insets: const EdgeInsets.only(top: 47, bottom: 34)),
    (name: 'phone-320', size: const Size(320, 568), ratio: 2.0, insets: const EdgeInsets.only(top: 20)),
    (name: 's22-360', size: const Size(360, 780), ratio: 3.0, insets: const EdgeInsets.only(top: 30, bottom: 16)),
    (name: 's22-384', size: const Size(384, 832), ratio: 2.8125, insets: const EdgeInsets.only(top: 30, bottom: 16)),
    (name: 'pixel8-412', size: const Size(412, 915), ratio: 2.625, insets: const EdgeInsets.only(top: 24, bottom: 16)),
  ];
  for (final theme in [CacheThemeId.dark, CacheThemeId.light]) {
    for (final w in screens) {
      testWidgets('${w.name}, ${theme.name}', (tester) async {
        await _draw(tester, name: w.name, size: w.size, ratio: w.ratio, insets: w.insets, theme: theme);
      });
    }
  }
}
