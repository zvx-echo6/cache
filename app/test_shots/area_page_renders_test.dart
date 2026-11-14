// A downloaded area's page (feat/downloaded-area-page), for the owner to review: one map area from the layers screen with its small
// map, size, date, Map part, the layers it holds, Show on map, Update and Delete, in the four themes at phone size (430 x 932); and,
// in Dark, the same area while it downloads and after it failed. Made-up area name and place. The live map is a platform view and is
// not drawn in a test, so the small map is a stand-in painted from the map palette with the area's outline as the map draws it.
// flutter test test_shots/area_page_renders_test.dart --update-goldens  (pictures in test_shots/area_page/)

import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/ui/area_page.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

const _out = 'area_page';

/// Open sea, so no real place is named.
const GeoBounds _box = GeoBounds(south: 0.10, west: -0.30, north: 0.20, east: -0.15);
const String _name = 'Example Ridge';

/// The small map's stand-in: land, a little water, and the area's outline in the middle (fill and line in the user areas' colour).
class _StandIn extends CustomPainter {
  _StandIn(this.p);
  final MapPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = p['land']);
    canvas.drawCircle(Offset(size.width * 0.12, size.height * 0.85), size.height * 0.35, Paint()..color = p['water']);
    canvas.drawCircle(Offset(size.width * 0.8, size.height * 0.2), size.height * 0.22, Paint()..color = p['park']);
    final r = Rect.fromCenter(center: size.center(Offset.zero), width: size.width * 0.42, height: size.height * 0.5);
    canvas.drawRect(r, Paint()..color = p['routeOffroad'].withValues(alpha: 0.18));
    canvas.drawRect(r, Paint()
      ..color = p['routeOffroad']
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_StandIn old) => old.p != p;
}

enum _State { done, running, failed }

void main() {
  setUpAll(loadShotFonts);
  tearDown(() => areaMapForTests = null);

  Future<void> shot(WidgetTester tester, CacheThemeId theme, _State state) async {
    final r = await SettingsRig.create(tester);
    phone(tester);
    areaMapForTests = (context, extent) => CustomPaint(painter: _StandIn(mapPaletteFor(theme)), size: Size.infinite);
    r.engine.clock = () => DateTime(2026, 6, 3, 10);
    r.engine.autoFinish = state == _State.done;
    final hill = r.maps.catalogueLayers.firstWhere((l) => l.id == 'hillshade');
    final a = await r.engine.download(hill.id, _box, label: _name);
    await tester.pump(const Duration(milliseconds: 100));
    switch (state) {
      case _State.done:
        break;
      case _State.running:
        a
          ..doneTiles = (a.totalTiles * 0.4).ceil()
          ..bytes = (a.totalTiles * 0.4).ceil() * 40000;
      case _State.failed:
        a
          ..phase = AreaPhase.failed
          ..error = 'connection lost'
          ..doneTiles = (a.totalTiles * 0.6).ceil()
          ..bytes = (a.totalTiles * 0.6).ceil() * 40000;
    }
    await tester.pumpWidget(shotApp(AreaPage(maps: r.maps, id: a.id), theme: theme));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await snap(tester, _out, '430-area-${state.name}-${theme.name}');
    await r.dispose(tester);
  }

  for (final theme in CacheThemeId.values) {
    testWidgets('area page, ready, ${theme.name}', (tester) => shot(tester, theme, _State.done));
  }
  testWidgets('area page, downloading, dark', (tester) => shot(tester, CacheThemeId.dark, _State.running));
  testWidgets('area page, failed, dark', (tester) => shot(tester, CacheThemeId.dark, _State.failed));
}
