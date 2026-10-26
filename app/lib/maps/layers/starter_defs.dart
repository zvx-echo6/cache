import 'dart:io';

import 'package:flutter/services.dart';

/// Where the starter layer definitions are bundled: the cache_search package's `layers/` folder.
const String kStarterLayersAssetDir = 'packages/cache_search/layers/';

/// Writes the starter definitions (hillshade, contours, elevation, OpenFreeMap, WorldCover, imagery) to [dir], where the
/// core reads them as its read-only definition folder (`layers.defs_dirs`). They are rewritten on every start, so an
/// app update brings new ones; what the user edits is saved as a user definition, never here.
Future<void> installStarterLayers(Directory dir, {AssetBundle? bundle}) async {
  final b = bundle ?? rootBundle;
  await dir.create(recursive: true);
  final manifest = await AssetManifest.loadFromAssetBundle(b);
  for (final asset in manifest.listAssets()) {
    if (!asset.startsWith(kStarterLayersAssetDir) || !asset.endsWith('.json')) continue;
    final name = asset.substring(kStarterLayersAssetDir.length);
    if (name.contains('/')) continue;
    final f = File('${dir.path}/$name');
    final text = await b.loadString(asset);
    if (!f.existsSync() || f.readAsStringSync() != text) await f.writeAsString(text);
  }
}
