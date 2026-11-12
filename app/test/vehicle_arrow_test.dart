// The phone map's position marker is the car's arrow (VehicleArrow, from CarOverlayPainter): an arrowhead turned by the heading,
// and the dot only while no heading was ever known.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/style/style_generator.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/ui/vehicle_arrow.dart';
import 'package:cache/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layer_fixtures.dart';

const _fill = ui.Color(0xFF1A73E8);
const _ring = ui.Color(0xFFFFFFFF);

/// The arrow turned [heading] degrees, drawn at density [d] with its position in the middle of a 100 pixel square, as RGBA bytes.
Future<({ByteData data, int size})> _draw(WidgetTester tester, double heading, {double d = 1, int size = 100}) async {
  final rec = ui.PictureRecorder();
  VehicleArrow.paintTurned(ui.Canvas(rec), ui.Offset(size / 2, size / 2), heading, _fill, _ring, d);
  final image = await rec.endRecording().toImage(size, size);
  final data = (await image.toByteData())!;
  return (data: data, size: size);
}

bool _drawn(({ByteData data, int size}) p, int dx, int dy) {
  final x = p.size ~/ 2 + dx, y = p.size ~/ 2 + dy;
  return p.data.getUint8((y * p.size + x) * 4 + 3) > 200;
}

bool _isFill(({ByteData data, int size}) p, int dx, int dy) {
  final o = ((p.size ~/ 2 + dy) * p.size + p.size ~/ 2 + dx) * 4;
  return p.data.getUint8(o) == 0x1A && p.data.getUint8(o + 1) == 0x73 && p.data.getUint8(o + 2) == 0xE8;
}

void main() {
  test('the arrow is the car\'s: the same numbers as CarOverlayPainter.kt', () {
    final kt = File('android/app/src/main/kotlin/com/happylittlellc/cache/car/CarOverlayPainter.kt').readAsStringSync();
    double k(String name) => double.parse(RegExp('const val $name = ([0-9.]+)f').firstMatch(kt)!.group(1)!);
    expect((VehicleArrow.width, VehicleArrow.height, VehicleArrow.ahead, VehicleArrow.outline, VehicleArrow.notch),
        (k('ARROW_W'), k('ARROW_H'), k('ARROW_AHEAD'), k('ARROW_OUTLINE'), k('ARROW_NOTCH')));
    expect(RegExp(r'const val ARROW_BITMAP_PAD = (\d+)').firstMatch(kt)!.group(1), '${VehicleArrow.bitmapPad}');
    // 30 x 34 at density 1, outline included.
    expect((VehicleArrow.width, VehicleArrow.height), (30.0, 34.0));
  });

  testWidgets('an arrow with a heading: a notched arrowhead in the position colour, the tip up for north', (tester) async {
    final p = (await tester.runAsync(() => _draw(tester, 0)))!;
    expect(_isFill(p, 0, 0), isTrue, reason: 'the middle of the arrow is the position colour');
    expect(_isFill(p, 0, -10), isTrue);
    expect(_drawn(p, 0, -18), isTrue, reason: 'the tip reaches 19 up from the position, outline included');
    expect(_drawn(p, 0, -21), isFalse);
    expect(_drawn(p, 0, 9), isFalse, reason: 'the notch at the back is cut out');
    expect(_drawn(p, -12, 12), isTrue, reason: 'a tail');
    expect(_drawn(p, 12, 12), isTrue, reason: 'the other tail');
    // The outline is the position ring, around the edge.
    final o = ((50 - 18) * 100 + 50) * 4;
    expect(p.data.getUint8(o + 3), greaterThan(200));
  });

  testWidgets('the arrow turns with the heading about the position', (tester) async {
    final east = (await tester.runAsync(() => _draw(tester, 90)))!;
    expect(_drawn(east, 18, 0), isTrue, reason: 'east: the tip is to the right');
    expect(_drawn(east, 0, -14), isFalse, reason: 'and no longer up');
    expect(_drawn(east, -9, 0), isFalse, reason: 'the notch is to the left');
    final south = (await tester.runAsync(() => _draw(tester, 180)))!;
    expect(_drawn(south, 0, 18), isTrue);
    expect(_drawn(south, 0, -9), isFalse);
    final west = (await tester.runAsync(() => _draw(tester, 270)))!;
    expect(_drawn(west, -18, 0), isTrue);
    // Nothing reaches further than VehicleArrow.reach, whichever way it turns.
    for (final h in [0.0, 37.0, 90.0, 135.0, 200.0, 315.0]) {
      final r = (await tester.runAsync(() => _draw(tester, h)))!;
      for (var y = -50; y < 50; y++) {
        for (var x = -50; x < 50; x++) {
          if (_drawn(r, x, y)) expect(math.sqrt(x * x + y * y), lessThanOrEqualTo(VehicleArrow.reach + 1.5), reason: 'heading $h at $x,$y');
        }
      }
    }
  });

  testWidgets('the picture is the arrow at the map\'s density, the position in its middle', (tester) async {
    for (final d in [1.0, 2.625, 3.0]) {
      final png = (await tester.runAsync(() => VehicleArrow.png(_fill, _ring, d)))!;
      final codec = (await tester.runAsync(() => ui.instantiateImageCodec(png)))!;
      final img = (await tester.runAsync(() => codec.getNextFrame()))!.image;
      expect(img.width, (30 * d).ceil() + 4);
      expect(img.height, (38 * d).ceil() + 4, reason: 'twice the room ahead, so the middle of the picture is the position');
    }
  });

  group('the dot only when no heading was ever known', () {
    for (final id in CacheThemeId.values) {
      test('style for ${id.name}', () {
        final template = jsonDecode(File('assets/map/omt_template.json').readAsStringSync()) as Map<String, dynamic>;
        final base = LayerDef.fromJson(Map<String, dynamic>.from(testCatalogue.firstWhere((j) => (j as Map)['id'] == 'openfreemap') as Map));
        final style = buildMapStyle(
          palette: mapPaletteFor(id),
          omtTemplate: template,
          layers: [StyleLayerUse(base)],
          tilesUrl: (d) => 'http://127.0.0.1:9/{z}/{x}/{y}',
          glyphsUrl: 'file:///fonts/{fontstack}/{range}.pbf',
        );
        final layers = {for (final l in (style['layers'] as List).cast<Map<String, dynamic>>()) l['id'] as String: l};
        expect(jsonEncode(layers[kPositionDot]!['filter']), contains('"!",["has","heading"]'), reason: 'the dot is hidden once a feature has a heading');
        expect(jsonEncode(layers[kPositionHeading]!['filter']), contains('"has","heading"'));
        expect(jsonEncode(layers[kPositionHeading]!['filter']), isNot(contains('"!"')));
        expect(layers[kPositionHeading]!['layout']['icon-image'], kHeadingImage);
        expect(layers[kPositionHeading]!['layout']['icon-rotation-alignment'], 'map');
        expect(layers[kPositionHeading]!['layout']['icon-rotate'], ['get', 'heading']);
      });
    }
  });
}
