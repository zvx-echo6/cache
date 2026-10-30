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

  /// True when the engine can draw [layerId] at the middle of [view] without the network: the tile is
  /// downloaded or was cached from an earlier view.
  Future<bool> hasTiles(String layerId, GeoBounds view, int zoom);

  /// The cost of downloading [area], before anything is downloaded. [zoom]: that zoom only (the off-road router's z12 elevation),
  /// never a lower one when the area is large; otherwise the layer's zooms, as deep as one download allows.
  Future<AreaEstimate> estimate(String layerId, GeoBounds area, {int? zoom});

  /// Starts the download; progress shows in [areasOf]. [zoom] as for [estimate]. [near]: the tiles come from there outwards
  /// (each zoom from the coarsest), so what is near is on the phone first.
  /// Throws a MobileDataBlocked (lib/settings/data_policy.dart) when the phone is on mobile data and downloads on mobile data are off, unless [anyway].
  Future<DownloadedArea> download(String layerId, GeoBounds area, {required String label, bool anyway = false, int? zoom, ({double lat, double lon})? near});

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
