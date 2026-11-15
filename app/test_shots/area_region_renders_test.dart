// Two pictures at phone size (390 x 844, Light), each page PUSHED with MaterialPageRoute over a parent screen the way the app opens
// it, so the AppBar shows its automatic back arrow (paneShowButton is null outside a two-pane detail, so `leading` falls to Flutter's
// own back arrow when the route can pop): 01, the downloaded-area page; 02, the region page of a region fully downloaded with all
// its parts (map, places, directions, off-road). The area's live map is a platform view, so a painted stand-in is used as in
// area_page_renders_test.dart.
// flutter test test_shots/area_region_renders_test.dart --update-goldens  (pictures in test_shots/area_region/)

import 'dart:io';

import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/ui/area_page.dart';
import 'package:cache/regions/ui/region_page.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/owner_state.dart';
import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

const _out = 'area_region';
const GeoBounds _box = GeoBounds(south: 0.10, west: -0.30, north: 0.20, east: -0.15);
const String _name = 'Example Ridge';

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

/// A plain parent screen with a button that pushes [page] with MaterialPageRoute (a push, so the route can pop).
Widget _parent(Widget Function() page) => Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(title: const Text('Parent')),
        body: Center(
          child: FilledButton(
            key: const ValueKey('open'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page())),
            child: const Text('Open'),
          ),
        ),
      ),
    );

Future<void> _push(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open')));
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.byType(BackButton), findsOneWidget);
}

void main() {
  setUpAll(loadShotFonts);
  tearDown(() => areaMapForTests = null);

  testWidgets('area page, pushed over a parent', (tester) async {
    final r = await SettingsRig.create(tester);
    phone(tester, size: const Size(390, 844));
    areaMapForTests = (context, extent) => CustomPaint(painter: _StandIn(mapPaletteFor(CacheThemeId.light)), size: Size.infinite);
    r.engine.clock = () => DateTime(2026, 6, 3, 10);
    r.engine.autoFinish = true;
    final hill = r.maps.catalogueLayers.firstWhere((l) => l.id == 'hillshade');
    final a = await r.engine.download(hill.id, _box, label: _name);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(shotApp(_parent(() => AreaPage(maps: r.maps, id: a.id))));
    await _push(tester);
    await snap(tester, _out, '01-area-page-pushed');
    await r.dispose(tester);
  });

  testWidgets('region page, all parts ready, pushed over a parent', (tester) async {
    final o = await OwnerState.boot(tester);
    phone(tester, size: const Size(390, 844));
    // Every part ready: the core's directions and places, the Forest Service map layer, and the off-road pack on the phone.
    o.core.finish('us-id');
    final usfs = o.legacy['usfs']!;
    usfs
      ..phase = AreaPhase.done
      ..interrupted = false
      ..error = null
      ..doneTiles = usfs.totalTiles;
    await tester.runAsync(() async {
      final pack = File('${(await o.regions.offroadDir()).path}/offroad-2026-10/idaho/offroad.sqlite');
      pack.parent.createSync(recursive: true);
      pack.writeAsBytesSync(const [0]);
      await o.regions.refresh();
    });
    await tester.pumpWidget(shotApp(_parent(() => RegionPage(regions: o.regions, id: 'us-id'))));
    await _push(tester);
    await snap(tester, _out, '02-region-page-complete');
    await o.dispose(tester);
  });
}
