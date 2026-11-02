import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Map fonts ship with the app (Noto Sans glyphs, SIL Open Font License 1.1) so labels work offline. MapLibre
/// reads glyphs by file address, so they are copied out of the app's assets once per app version.
class MapAssets {
  static const String _prefix = 'assets/map/fonts/';
  static const String _version = '1';

  /// The `glyphs` address for the style: a folder per font, files per range of characters.
  static Future<String> glyphsUrl({Directory? dirOverride}) async {
    final base = dirOverride ?? Directory('${(await getApplicationSupportDirectory()).path}/map_fonts');
    final marker = File('${base.path}/.version');
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final names = [for (final a in manifest.listAssets()) if (a.startsWith(_prefix)) a];
    var ok = marker.existsSync() && marker.readAsStringSync() == _version;
    if (ok) {
      for (final a in names) {
        if (!File('${base.path}/${a.substring(_prefix.length)}').existsSync()) ok = false;
      }
    }
    if (!ok) {
      for (final a in names) {
        final f = File('${base.path}/${a.substring(_prefix.length)}');
        await f.parent.create(recursive: true);
        final data = await rootBundle.load(a);
        await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      }
      await marker.writeAsString(_version);
    }
    return 'file://${base.path}/{fontstack}/{range}.pbf';
  }

  /// The heading marker: a small triangle near the top edge of a transparent square, so that placed on the
  /// position dot and turned by the heading it circles the dot. Drawn with the palette's position colours.
  static Future<Uint8List> headingMarker(ui.Color fill, ui.Color outline, {int size = 96}) async {
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    final s = size.toDouble();
    final path = ui.Path()
      ..moveTo(s / 2, s * 0.04)
      ..lineTo(s / 2 + s * 0.13, s * 0.2)
      ..lineTo(s / 2 - s * 0.13, s * 0.2)
      ..close();
    c.drawPath(
        path,
        ui.Paint()
          ..color = outline
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = s * 0.05
          ..strokeJoin = ui.StrokeJoin.round);
    c.drawPath(path, ui.Paint()..color = fill);
    final img = await rec.endRecording().toImage(size, size);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }
}
