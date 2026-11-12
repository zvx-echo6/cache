import 'dart:io';
import 'package:flutter/services.dart';
import '../../app_fs.dart';
import '../../platform.dart' as plat;

/// Map fonts ship with the app (Noto Sans glyphs, SIL Open Font License 1.1) so labels work offline. MapLibre
/// reads glyphs by file address, so they are copied out of the app's assets once per app version.
class MapAssets {
  static const String _prefix = 'assets/map/fonts/';
  static const String _version = '1';

  /// The `glyphs` address for the style: a folder per font, files per range of characters.
  static Future<String> glyphsUrl({Directory? dirOverride}) async {
    // In a browser the fonts are served with the app: Flutter publishes each asset at assets/<asset key> beside the page, and the
    // sign-in cookie goes with MapLibre's same-origin requests. The address is absolute because MapLibre's workers cannot resolve
    // a relative one. Nothing is copied.
    if (plat.isWeb) return '${Uri.base.resolve('assets/')}assets/map/fonts/{fontstack}/{range}.pbf';
    final base = dirOverride ?? Directory('${await appSupportPath()}/map_fonts');
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
}
