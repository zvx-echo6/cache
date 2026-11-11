import 'dart:io';

import '../app_state.dart';
import '../maps/layers/layer_engine.dart';
import '../notebook/notebook_state.dart';
import '../notebook/sync/sync_engine.dart' show NotebookSync;
import '../regions/regions_state.dart';
import '../settings/data_kinds.dart';
import '../sources/libraries_state.dart';
import '../sources/sources_state.dart';
import '../video/video_state.dart';

/// The items of each kind under "Shared with linked devices", as the app lists them on this device, and what a path a linked
/// device lists is ([DataKind.items], [DataKind.remoteItem]). An item's path is where it sits in its shared folder, as a sync
/// pattern; the same item on two devices has the same path.

/// [path] relative to [root] with "/" between its parts, or null when it is not inside it.
String? relativeTo(Directory? root, String path) {
  if (root == null) return null;
  final r = root.path.replaceAll(r'\', '/');
  final p = path.replaceAll(r'\', '/');
  final prefix = r.endsWith('/') ? r : '$r/';
  return p.startsWith(prefix) ? p.substring(prefix.length) : null;
}

/// The first [n] parts of a relative path.
String _head(String rel, int n) => rel.split('/').take(n).join('/');

/// Library: each ZIM (the `library` folder) and each library of your own (a folder in `libraries`).
List<ShareItem> libraryItems(SourcesState sources, LibrariesState libraries) => [
  for (final z in sources.zims)
    ShareItem(share: 'library', path: _head(relativeTo(sources.zimsDir, z.path) ?? z.fileName, 1), name: sources.titleOf(z), bytes: z.size),
  for (final l in libraries.libraries) ShareItem(share: 'libraries', path: l.folderName, name: libraries.titleOf(l), bytes: l.size),
];

/// A ZIM or a library on a linked device only; anything else in the ZIMs' folder is not an item.
ShareItem? libraryRemoteItem(String share, String path, int bytes) {
  if (share == 'libraries') return ShareItem(share: share, path: path, name: path.replaceAll(RegExp(r'[-_]+'), ' '), bytes: bytes);
  return path.toLowerCase().endsWith('.zim') ? ShareItem.plain(share, path, bytes) : null;
}

/// What goes with a ZIM in the Library's shared folder without being an item: the icon saved beside it (`<zim>.icon.png`), so a
/// ZIM that is switched off, or fetched on its own, takes its picture with it and leaves none behind.
List<String> libraryAlongside(String share, String path) => share == 'library' && path.toLowerCase().endsWith('.zim') ? ['$path.icon.png'] : const [];

/// The name of the regions' item: their road routing, places and off-road packs (kept together, shared by every region).
const String kDirectionsItemName = 'Directions, places and off-road';

/// Maps: each map layer with downloaded areas (its file in `maps/store/`, with SQLite's -wal beside it) and the regions'
/// directions, places and off-road together (the `regions` folder: one database and tiles every region shares, so it cannot be
/// split by region).
List<ShareItem> mapItems(LayerEngine engine, RegionsState regions) {
  final byLayer = <String, int>{};
  for (final a in engine.allAreas) {
    byLayer[a.layerId] = (byLayer[a.layerId] ?? 0) + a.bytes;
  }
  final local = regions.local;
  final rest = local.fold<int>(0, (n, r) => n + r.routingBytes + r.placesBytes + r.offroadBytes);
  return [
    for (final e in byLayer.entries) ShareItem(share: 'maps', path: 'store/${e.key}.sqlite*', name: engine.layer(e.key)?.title ?? e.key, bytes: e.value),
    if (local.any((r) => r.hasRouting || r.hasPlaces || r.hasOffroad)) ShareItem(share: 'regions', path: '**', name: kDirectionsItemName, bytes: rest),
  ];
}

/// A map layer's file, or the regions' folder, on a linked device; the layer engine's other files travel with the kind.
ShareItem? mapRemoteItem(LayerEngine engine, String share, String path, int bytes) {
  if (share == 'regions') return ShareItem(share: share, path: '**', name: kDirectionsItemName, bytes: bytes);
  final m = RegExp(r'^store/(.+?)\.sqlite').firstMatch(path);
  if (m == null) return null;
  final id = m.group(1)!;
  return ShareItem(share: share, path: 'store/$id.sqlite*', name: engine.layer(id)?.title ?? id, bytes: bytes);
}

/// Models: each chat model, and the search model.
List<ShareItem> modelItems(AppState app) => [
  for (final m in [...app.models, ?app.searchModel])
    ShareItem(share: 'models', path: _head(relativeTo(app.modelsDir, m.path) ?? m.fileName, 1), name: app.displayName(m), bytes: m.size),
];

/// A model on a linked device only.
ShareItem? modelRemoteItem(String share, String path, int bytes) => path.toLowerCase().endsWith('.gguf') ? ShareItem.plain(share, path, bytes) : null;

/// Notebooks: each notebook (its folder in notebook sync's folder). A private one is listed, and is off until its "Include in
/// sync and sharing" is on.
List<ShareItem> notebookItems(NotebookState notebooks) => [
  for (final n in notebooks.notebooks)
    ShareItem(
      share: 'notebooks',
      path: NotebookSync.folderNameOf(n),
      name: n.name,
      private: n.private,
      on: n.private ? (notebooks.privateSharing?.included(n.id) ?? false) : null,
    ),
];

/// A notebook on a linked device only; the photos folder every notebook uses travels with the kind.
ShareItem? notebookRemoteItem(String share, String path, int bytes) =>
    path == 'photos' ? null : ShareItem(share: share, path: path, name: path, bytes: bytes);

/// Switches a private notebook on or off: its "Include in sync and sharing".
Future<void> setNotebookShared(NotebookState notebooks, ShareItem it, bool on) async {
  final n = notebooks.notebooks.where((n) => NotebookSync.folderNameOf(n) == it.path).firstOrNull;
  if (n == null) return;
  await notebooks.privateSharing?.setIncluded(n.id, on);
}

/// Videos: each saved video (its folder, `downloads/<site>/<video>`).
List<ShareItem> videoItems(VideoState video) => [
  for (final v in video.saved)
    ShareItem(
      share: 'videos',
      path: switch (relativeTo(video.dir, v.path)) {
        final rel? when rel.split('/').length >= 3 => _head(rel, 3),
        _ => 'downloads/${v.instance}/${v.uuid}',
      },
      name: v.title.isEmpty ? v.uuid : v.title,
      bytes: v.size,
    ),
];

/// A saved video on a linked device only, named after its site (its title is in its folder, which is not here yet).
ShareItem? videoRemoteItem(String share, String path, int bytes) {
  final parts = path.split('/');
  if (parts.length != 3 || parts.first != 'downloads') return null;
  return ShareItem(share: share, path: path, name: 'Video from ${parts[1]}', bytes: bytes);
}
