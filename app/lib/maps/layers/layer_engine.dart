import 'package:flutter/foundation.dart';

import '../geo.dart';
import 'layer_def.dart';

/// The seam between the Maps tab and the layer engine in the Rust core (cs_layers_*, see [CoreLayerEngine]): a catalogue
/// of layer definitions, a local tile server on 127.0.0.1, area downloads and on-phone contours.
///
/// The map reads tiles only from [tilesUrl] (`GET /layers/{id}/{z}/{x}/{y}`); it never knows where a layer
/// comes from.
abstract class LayerEngine extends ChangeNotifier {
  /// Opens the tile server and reads the catalogue.
  Future<void> start();

  /// Why layers cannot be used on this device, or null.
  String? get problem;

  bool get ready;

  /// True when the tile server could not start because the system refuses the app network access (Android can
  /// switch it off). The screen then asks the user, and calls [start] again.
  bool get blockedByPermission => false;

  /// Every catalogue layer, in drawing order (bottom first).
  List<LayerDef> get layers;

  LayerDef? layer(String id) {
    for (final l in layers) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// `http://127.0.0.1:<port>/layers/<id>/{z}/{x}/{y}` for MapLibre's `tiles` list.
  String tilesUrl(String id);

  /// The layer's TileJSON, served next to its tiles.
  String tileJsonUrl(String id);

  /// Whether the phone has a connection right now (as far as the engine can tell).
  bool get online;

  /// Re-checks the connection (cheap, at most every few seconds).
  Future<void> refreshOnline();

  /// Counts the times the connection came back. It is part of [tilesUrl] and [tileJsonUrl] (and of the map's style key), so
  /// the map loads its sources again: tiles it could not have while offline are asked for again.
  int get sourcesGeneration => 0;

  /// The tile server's port on this device (0: none, or not on this device). It is part of the map's style key: a new port
  /// means the map's sources have new addresses.
  int get port => 0;

  /// Asks the core for its tile server again. iOS can take a suspended app's listening socket away; the core then starts a
  /// new server on a new port, and listeners hear of it. Called when the app comes to the front, when a car screen connects
  /// and when the car's map asks for its style.
  Future<void> recheckServer() async {}

  /// True when the engine can draw [layerId] at the middle of [view] without the network: the tile is
  /// downloaded or was cached from an earlier view.
  Future<bool> hasTiles(String layerId, GeoBounds view, int zoom);

  /// The cost of downloading [area], before anything is downloaded. [zoom]: that zoom only (the off-road router's z12 elevation),
  /// never a lower one when the area is large; otherwise the layer's zooms, as deep as one download allows.
  Future<AreaEstimate> estimate(String layerId, GeoBounds area, {int? zoom});

  /// Starts the download; progress shows in [areasOf]. [zoom] as for [estimate]. [near]: the tiles come from there outwards
  /// (each zoom from the coarsest), so what is near is on the phone first. [outline]: the area's outline inside [area], as rings
  /// of [lon, lat] (a region in parts, holes), read even-odd, so parts make their union; only the tiles it touches are downloaded.
  /// The zoom is still chosen by the estimate of [area], the box.
  /// Throws a MobileDataBlocked (lib/settings/data_policy.dart) when the phone is on mobile data and downloads on mobile data are off, unless [anyway].
  Future<DownloadedArea> download(String layerId, GeoBounds area, {required String label, bool anyway = false, int? zoom, ({double lat, double lon})? near, List<List<List<double>>>? outline, MapFile? file});

  /// Downloaded and downloading areas of a layer.
  List<DownloadedArea> areasOf(String layerId);

  /// The layer [layerId]'s tiles are downloaded as: hillshade and contour lines are drawn from the elevation layer's tiles, so their
  /// areas are the elevation layer's (and list under all three). Itself for any other layer.
  String downloadLayerOf(String layerId) => layer(layerId)?.raw['derived_from'] as String? ?? layerId;

  /// Every downloaded area once (an elevation area lists under elevation, hillshade and contour lines).
  List<DownloadedArea> get allAreas {
    final seen = <String>{};
    return [
      for (final l in layers)
        for (final a in areasOf(l.id))
          if (seen.add(a.id)) a,
    ];
  }

  /// Stops a running download and removes what it fetched.
  Future<void> cancel(String areaId);

  /// Pauses a running download: it stops and keeps what it fetched (the area reads as stopped part way, [AreaPhase.failed] with no
  /// error and [DownloadedArea.paused]); [update] carries it on.
  Future<void> pause(String areaId) => cancel(areaId);

  Future<void> delete(String areaId);

  /// Fetches the area again and swaps it in when complete (the old copy stays in use until then).
  Future<void> update(String areaId, {bool anyway = false});

  int storageOf(String layerId);

  int get storageTotal;

  /// Advanced: adds or replaces a definition from its JSON.
  Future<void> saveDefinition(String json);

  /// True for a definition the user added or edited (removing it brings back the catalogue's own version, if any).
  bool canRemove(String id) => false;

  Future<void> removeDefinition(String id);
}

/// A region's pre-cut map file (the region list's `basemap_file`): one archive of the layer's tiles cut to the region's outline,
/// where it is, its size and SHA-256, and the [planet] build (the layer's update version) it was cut from. Given to
/// [LayerEngine.download], the core fetches it whole (carrying on from a partial file), checks it and copies its tiles into the
/// layer's store; when anything is wrong with it, or it was cut from another build, the area downloads by range reads as without
/// it. Nothing on screen changes either way.
class MapFile {
  const MapFile({required this.url, required this.bytes, required this.sha256, required this.planet});

  final String url;
  final int bytes;
  final String sha256;
  final String planet;

  /// The entry from the region list; null for anything that is not a usable one (a field missing or of another type, no bytes,
  /// a SHA-256 that is not 64 hex digits, an address that is not https), so the region downloads as it did before files.
  static MapFile? fromJson(Object? j) {
    if (j is! Map) return null;
    final url = j['url'], bytes = j['bytes'], sha = j['sha256'], planet = j['planet'];
    if (url is! String || bytes is! int || sha is! String || planet is! String) return null;
    if (bytes <= 0 || planet.isEmpty || !url.startsWith('https://') || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha)) return null;
    return MapFile(url: url, bytes: bytes, sha256: sha.toLowerCase(), planet: planet);
  }

  /// What the core's download job takes as its "file".
  Map<String, Object> toJson() => {'url': url, 'bytes': bytes, 'sha256': sha256, 'planet': planet};

  @override
  bool operator ==(Object other) => other is MapFile && other.url == url && other.bytes == bytes && other.sha256 == sha256 && other.planet == planet;

  @override
  int get hashCode => Object.hash(url, bytes, sha256, planet);
}
