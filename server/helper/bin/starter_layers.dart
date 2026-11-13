import 'dart:io';

/// The starter map layer definitions on Cache Server, as the phone puts them in place at every start (the app's
/// `installStarterLayers`, app/lib/maps/layers/starter_defs.dart): hillshade, contours, the elevation layer (Mapterhorn), the
/// imagery, WorldCover and OpenFreeMap.
///
/// The server's web build carries them (`<web>/assets/packages/cache_search/layers/*.json`); the server gives that folder as
/// `CACHE_STARTER_LAYERS`. Each top-level `.json` file there is written to [to] (`<support>/layer-defs`, the core's read-only
/// definition folder) when it is missing or differs, so an update of Cache brings new ones; anything else in either folder is left
/// alone. Without them the browser had no elevation (no route elevation chart), no hills, contours or imagery. Returns how many
/// files were written; a folder that cannot be read installs nothing.
int installStarterLayers(Directory from, Directory to, {void Function(String message)? log}) {
  if (!from.existsSync()) {
    log?.call('starter map layers: $from is not there');
    return 0;
  }
  var written = 0;
  try {
    to.createSync(recursive: true);
    final files = from.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final name = f.uri.pathSegments.last;
      final text = f.readAsStringSync();
      final dest = File('${to.path}/$name');
      if (dest.existsSync() && dest.readAsStringSync() == text) continue;
      dest.writeAsStringSync(text);
      written++;
    }
    log?.call('starter map layers: ${files.length} in place ($written written)');
  } catch (e) {
    log?.call('starter map layers could not be put in place: $e');
  }
  return written;
}
