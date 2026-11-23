import 'dart:math' as math;
import 'dart:typed_data';

import 'mvt.dart';

/// What the tile server said about one tile.
sealed class LandTile {
  const LandTile();
}

/// The tile's bytes (the tile server unzips vector tiles).
class LandTileData extends LandTile {
  const LandTileData(this.bytes);
  final Uint8List bytes;
}

/// The source has no tile here: nothing is mapped in this square (an answer, with or without a connection).
class LandTileEmpty extends LandTile {
  const LandTileEmpty();
}

/// The tile is not on this device and there is no connection, or it could not be read: no answer.
class LandTileUnavailable extends LandTile {
  const LandTileUnavailable();
}

typedef LandTileFetch = Future<LandTile> Function(int z, int x, int y);

/// The land layer's own attributes at a point (PAD-US 4.1 field names, as the layer's tiles carry them).
class LandHit {
  const LandHit({required this.category, required this.manager, required this.managerType, required this.ownerType, required this.unit, required this.acres});

  /// Fee, Designation, Easement, Proclamation, Marine, Other or Unknown.
  final String category;

  /// `Mang_Name`: a short code ("BLM", "USFS", "SPR").
  final String manager;

  /// `Mang_Type`: FED, STAT, LOC, TRIB, NGO, PVT, JNT, DIST, TERR or UNK.
  final String managerType;
  final String ownerType;

  /// `Unit_Nm`: the unit's own name ("Sawtooth National Forest"); empty when there is none.
  final String unit;
  final double acres;
}

/// What the card says about the land at a point. [hit] is null when the layer has no area there.
class LandAnswer {
  const LandAnswer(this.hit);

  final LandHit? hit;

  /// The card's line, after "Land: ".
  String get text => landText(hit);

  /// The unit's own name when the layer gives one.
  String? get unit => (hit?.unit.isNotEmpty ?? false) ? hit!.unit : null;
}

/// Manager codes of PAD-US 4.1 (`Mang_Name`) in plain words. A code left out (not sure what it stands for) falls back to the
/// manager type's words, never to a guess.
const Map<String, String> kLandManagers = {
  'BLM': 'Bureau of Land Management',
  'USFS': 'Forest Service',
  'NPS': 'National Park Service',
  'FWS': 'Fish and Wildlife Service',
  'USBR': 'Bureau of Reclamation',
  'USACE': 'Army Corps of Engineers',
  'DOD': 'Department of Defense',
  'DOE': 'Department of Energy',
  'TVA': 'Tennessee Valley Authority',
  'NOAA': 'NOAA',
  'NRCS': 'Natural Resources Conservation Service',
  'ARS': 'Agricultural Research Service',
  'BOEM': 'Bureau of Ocean Energy Management',
  'OTHF': 'Other federal agency',
  'SLB': 'State land board',
  'SDNR': 'State natural resources agency',
  'SPR': 'State parks',
  'SFW': 'State fish and wildlife agency',
  'SDOL': 'State department of lands',
  'SDC': 'State conservation department',
  'OTHS': 'Other state agency',
  'CITY': 'City government',
  'CNTY': 'County government',
  'REG': 'Regional agency',
  'RWD': 'Regional water district',
  'TRIB': 'Tribal government',
  'NGO': 'Nonprofit conservation group',
  'PVT': 'Private owner',
};

/// `Mang_Type` in plain words.
const Map<String, String> kLandManagerTypes = {
  'FED': 'Federal agency',
  'STAT': 'State agency',
  'LOC': 'Local government',
  'TRIB': 'Tribal government',
  'NGO': 'Nonprofit conservation group',
  'PVT': 'Private owner',
  'JNT': 'Joint management',
  'DIST': 'Special district',
  'TERR': 'Territorial government',
};

String? _managerLabel(LandHit h) => kLandManagers[h.manager] ?? kLandManagerTypes[h.managerType];

/// The card's words for the land at a point. A polygon is the whole answer only for land the layer calls Fee (owned and managed)
/// or Designation; a boundary the layer calls Proclamation can hold private land inside it, and an Easement is not ownership.
/// Nothing in the layer is "Not public land in our data", which does not say who owns it.
String landText(LandHit? h) {
  if (h == null) return 'Not public land in our data';
  final who = _managerLabel(h);
  if (who == null) return 'Public land, manager not recorded';
  switch (h.category) {
    case 'Proclamation':
      return 'Inside the boundary of $who (may include private land)';
    case 'Easement':
      return 'Easement held by $who (the land may be private)';
    default:
      return h.manager == 'PVT' ? 'Private land with protection' : who;
  }
}

/// Which polygon speaks for a point when several cover it: ownership first (Fee), then a designation, then the weaker claims;
/// among equals the smallest unit.
const List<String> _categoryOrder = ['Fee', 'Designation', 'Other', 'Unknown', 'Marine', 'Easement', 'Proclamation'];

LandHit? _best(List<LandHit> hits) {
  if (hits.isEmpty) return null;
  int rank(LandHit h) {
    final i = _categoryOrder.indexOf(h.category);
    return i < 0 ? _categoryOrder.length : i;
  }

  final sorted = [...hits]..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.acres.compareTo(b.acres);
    });
  return sorted.first;
}

String _str(Object? v) => v is String ? v : '';

/// The land at ([lat], [lon]) from the public-lands layer's tile at [zoom], read through [fetch]. Null when the answer is not known
/// (the tile is not on the phone, could not be read, or is not a vector tile): the card then shows nothing, never a guess.
Future<LandAnswer?> landAt(double lat, double lon, LandTileFetch fetch, {int zoom = 12}) async {
  final n = 1 << zoom;
  final la = lat.clamp(-85.0511287798, 85.0511287798);
  final fx = (lon + 180) / 360 * n;
  final rad = la * math.pi / 180;
  final fy = (1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) / 2 * n;
  final tx = fx.floor(), ty = fy.floor();
  if (ty < 0 || ty >= n) return null;
  final t = await fetch(zoom, ((tx % n) + n) % n, ty);
  switch (t) {
    case LandTileUnavailable():
      return null;
    case LandTileEmpty():
      return const LandAnswer(null);
    case LandTileData(:final bytes):
      final List<MvtLayer> layers;
      try {
        layers = readMvtPolygons(bytes);
      } on Object {
        return null;
      }
      final hits = <LandHit>[];
      var sawLayer = false;
      for (final l in layers) {
        if (l.name != 'public_lands') continue;
        sawLayer = true;
        final x = (fx - tx) * l.extent, y = (fy - ty) * l.extent;
        for (final p in l.polygons) {
          if (!p.contains(x, y)) continue;
          final props = p.properties;
          final acres = props['GIS_Acres'];
          hits.add(LandHit(
            category: _str(props['Category']),
            manager: _str(props['Mang_Name']),
            managerType: _str(props['Mang_Type']),
            ownerType: _str(props['Own_Type']),
            unit: _str(props['Unit_Nm']).trim(),
            acres: acres is num ? acres.toDouble() : double.infinity,
          ));
        }
      }
      // A tile with no such layer is not this layer's tile: no answer.
      return sawLayer ? LandAnswer(_best(hits)) : null;
  }
}
