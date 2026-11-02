import 'dart:io';

import 'package:flutter/services.dart';

/// Where the starter layer definitions are bundled: the cache_search package's `layers/` folder.
const String kStarterLayersAssetDir = 'packages/cache_search/layers/';

/// Writes the starter definitions (hillshade, contours, elevation, OpenFreeMap, WorldCover, imagery) to [dir], where the
/// core reads them as its read-only definition folder (`layers.defs_dirs`). They are rewritten on every start, so an
/// app update brings new ones; what the user edits is saved as a user definition, never here.
Future<void> installStarterLayers(Directory dir, {AssetBundle? bundle}) => _installJson(dir, kStarterLayersAssetDir, bundle);

/// Where the live data source definitions (weather, alerts) are bundled: the cache_search package's `sources/` folder.
const String kLiveSourcesAssetDir = 'packages/cache_search/sources/';

/// The text of each live data source definition the app ships (the built-in sources: weather and alerts). They ship in the app from
/// the same commit as the core, because the core reads them strictly: a definition with a field an older core does not know
/// (alerts.json's `none_label`) is refused. The weather part of the app puts the ones that are switched on in the core's folder.
Future<List<String>> readLiveSourceAssets({AssetBundle? bundle}) async {
  final b = bundle ?? rootBundle;
  final manifest = await AssetManifest.loadFromAssetBundle(b);
  final names = [
    for (final asset in manifest.listAssets())
      if (asset.startsWith(kLiveSourcesAssetDir) && asset.endsWith('.json') && !asset.substring(kLiveSourcesAssetDir.length).contains('/')) asset,
  ]..sort();
  return [for (final n in names) await b.loadString(n)];
}

Future<void> _installJson(Directory dir, String assetDir, AssetBundle? bundle) async {
  final b = bundle ?? rootBundle;
  await dir.create(recursive: true);
  final manifest = await AssetManifest.loadFromAssetBundle(b);
  for (final asset in manifest.listAssets()) {
    if (!asset.startsWith(assetDir) || !asset.endsWith('.json')) continue;
    final name = asset.substring(assetDir.length);
    if (name.contains('/')) continue;
    final f = File('${dir.path}/$name');
    final text = await b.loadString(asset);
    if (!f.existsSync() || f.readAsStringSync() != text) await f.writeAsString(text);
  }
}
