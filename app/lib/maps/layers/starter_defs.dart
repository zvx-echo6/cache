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

/// Writes the live data source definitions to [dir] (the core's `live.sources_dir`), rewritten on every start. They ship in the app
/// from the same commit as the core, because the core reads them strictly: a definition with a field an older core does not know
/// (alerts.json's `none_label`) is refused. Files in [dir] the app does not ship (a definition someone added) are left alone.
Future<void> installLiveSources(Directory dir, {AssetBundle? bundle}) => _installJson(dir, kLiveSourcesAssetDir, bundle);

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
