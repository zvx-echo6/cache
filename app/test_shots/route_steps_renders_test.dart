// Stepping through a route's turns before Start, for the owner to look at: the whole-route preview with the back and next arrows
// beside Start, and a turn shown (one with lane arrows, a stop, the last turn), on a phone 390 and 320 points wide and in the
// Linux desktop layout of the same screen (the browser build: a window 1280 wide, no position, the route from a chosen start),
// each in the Dark and the Light theme.
// The map itself is a platform view and is not drawn; the round marker shows where the camera the screen asked for puts the turn
// shown (worked out from that camera), so it can be seen that the turn is clear of the card. The route and places are made up.
// flutter test test_shots/route_steps_renders_test.dart --update-goldens  (pictures in test_shots/route_steps/)

import 'dart:io';

import 'package:cache/linux_ui.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/nav/guidance_camera.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../test/location_service_test.dart' show FakeSource;
import '../test/nav_fakes.dart';
import '../test/navigation_camera_test.dart' show CameraController, NoSurface;
import '../test/route_steps_test.dart' show stepRouteJson;
import '../test/support/test_layer_engine.dart';
import 'shot_kit.dart';

const _out = 'route_steps';

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

const _to = MapPlace(id: 'place:test:1', type: 'place', name: 'Place 1', kind: '', address: '', lat: 42.5, lon: -113.5, matched: 'name');
const _from = MapPlace(id: 'place:test:0', type: 'place', name: 'Place 0', kind: '', address: '', lat: 42.5, lon: -113.8, matched: 'name');
const _stop = MapPlace(id: 'place:test:2', type: 'place', name: 'Market 1', kind: '', address: '', lat: 42.5, lon: -113.65, matched: 'name');

/// [step]: the turn the card shows (from 0), or null for the preview with its button. [linux]: the Linux desktop layout (no
/// position; the route from a chosen start).
Future<void> _draw(WidgetTester tester, {required String name, required Size size, required double ratio, required EdgeInsets insets, required CacheThemeId theme, int? step, bool stop = false, bool linux = false}) async {
  phone(tester, size: size, ratio: ratio);
  rootBundle.clear();
  if (linux) {
    debugLinuxUi = true;
    addTearDown(() => debugLinuxUi = null);
  }
  final dir = Directory.systemTemp.createTempSync('route-steps-renders-');
  final originalPlatform = MapLibrePlatform.createInstance;
  MapLibrePlatform.createInstance = () => NoSurface();
  final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
  final engine = TestLayerEngine();
  final maps = MapsState(engine: engine, settingsDirOverride: dir);
  final backend = FakeBackend()..onRoute = ((to, mode, from) async => MapRoute.fromJson(stepRouteJson(id: 'r${stop ? 's' : ''}', turns: 7, lanes: true, stop: stop)));
  final nav = NavState(backend: backend, location: location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
  final camera = CameraController();
  final marker = ValueNotifier<Offset?>(null);
  try {
    await tester.runAsync(() async {
      await location.init();
      await engine.start();
    });
    await tester.pumpWidget(shotApp(
      Stack(children: [
        Positioned.fill(
          child: MapsScreen(location: location, maps: maps, nav: nav, themeId: theme, glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf'),
        ),
        Positioned.fill(child: _Marker(marker)),
      ]),
      theme: theme,
      insets: insets,
      desktop: linux,
    ));
    for (var i = 0; i < 600 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(camera);
    map.onStyleLoadedCallback!();
    await tester.pump();
    await tester.runAsync(() async {
      if (linux) {
        nav.setFrom(_from);
        nav.closeSearch();
      } else {
        location.publish(fixAt(42.5, -113.8));
      }
      await nav.openDirections(_to);
      if (stop) await nav.addStop(_stop);
    });
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await settle();
    expect(nav.phase, NavPhase.previewing);
    if (step != null) {
      // The panel's next arrow shows the first turn; each next after it the one after.
      for (var i = 0; i <= step; i++) {
        await tester.tap(find.byKey(const ValueKey('step-next')));
        await settle();
      }
      final last = camera.cameras.lastWhere((c) => (c as List).first == 'newCameraPosition') as List;
      final c = (last[1] as Map).cast<String, dynamic>();
      final t = (c['target'] as List).cast<num>();
      final m = nav.route!.maneuvers[step];
      marker.value = screenPointFor(m.lat, m.lon, centreLat: t[0].toDouble(), centreLon: t[1].toDouble(), bearing: 0, zoom: (c['zoom'] as num).toDouble(), map: tester.getSize(find.byType(MapLibreMap)));
      await tester.pump();
    }
    await snap(tester, _out, '$name-${theme == CacheThemeId.light ? 'light' : 'dark'}');
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    MapLibrePlatform.createInstance = originalPlatform;
    marker.dispose();
    camera.dispose();
    nav.dispose();
    maps.dispose();
    location.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  }
}

void main() {
  setUpAll(loadShotFonts);

  final List<({String name, Size size, double ratio, EdgeInsets insets, bool linux})> screens = [
    (name: 'phone-390', size: const Size(390, 844), ratio: 3.0, insets: const EdgeInsets.only(top: 47, bottom: 34), linux: false),
    (name: 'phone-320', size: const Size(320, 568), ratio: 2.0, insets: const EdgeInsets.only(top: 20), linux: false),
    (name: 'linux-1280', size: const Size(1280, 800), ratio: 1.0, insets: EdgeInsets.zero, linux: true),
  ];
  // The whole route (no turn shown), a turn with lane arrows, a stop, the last turn.
  const List<({String name, int? step, bool stop})> shots = [(name: 'preview', step: null, stop: false), (name: 'step-lanes', step: 1, stop: false), (name: 'step-stop', step: 2, stop: true), (name: 'step-last', step: 6, stop: false)];
  for (final theme in [CacheThemeId.dark, CacheThemeId.light]) {
    for (final w in screens) {
      for (final s in shots) {
        testWidgets('${w.name} ${s.name}, ${theme.name}', (tester) async {
          await _draw(tester, name: '${w.name}-${s.name}', size: w.size, ratio: w.ratio, insets: w.insets, theme: theme, step: s.step, stop: s.stop, linux: w.linux);
        });
      }
    }
  }
}
