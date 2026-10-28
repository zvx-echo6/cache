import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../files.dart';
import 'geo.dart';
import 'layers/layer_def.dart';
import 'layers/layer_engine.dart';
import 'network_access.dart';
import 'palette/map_palette.dart';
import 'style/protomaps_layout.dart';
import 'style/style_generator.dart';

/// The first sentence of a credit, without its final full stop, and at most 80 characters.
String shortAttribution(String credit) {
  final end = credit.indexOf(RegExp(r'[.;] '));
  var t = (end < 0 ? credit : credit.substring(0, end)).trim();
  if (t.endsWith('.')) t = t.substring(0, t.length - 1);
  return t.length > 80 ? '${t.substring(0, 79).trimRight()}…' : t;
}

/// How the camera follows the phone.
enum FollowMode {
  /// The map stays where the user put it.
  free,

  /// The map keeps the phone's position in the middle, north up.
  follow,

  /// The same, and the map turns so the way the phone is heading points up.
  headingUp,
}

/// Where the map was left, to open it there next time.
class SavedCamera {
  const SavedCamera(this.lat, this.lon, this.zoom);
  final double lat;
  final double lon;
  final double zoom;
}

/// The Maps tab's state: which layers are on and how opaque, the camera, the offline notice. The layer
/// engine owns the catalogue and the tiles; this owns what the user chose to look at.
class MapsState extends ChangeNotifier {
  MapsState({required this.engine, this.settingsDirOverride, NetworkAccess? network})
      : _network = network ?? PlatformNetworkAccess();

  final LayerEngine engine;
  final NetworkAccess _network;

  /// True while the app lacks network access and has not been allowed to ask yet or was refused: the map
  /// screen shows why and a button, because nothing on the Maps tab works without it.
  bool needsNetworkAccess = false;

  /// The user said no to the system prompt (so the way back is the phone's settings).
  bool networkRefused = false;

  /// Test hook.
  final Directory? settingsDirOverride;

  final Set<String> _enabled = {};
  final Map<String, double> _opacity = {};
  bool _hadSettings = false;
  SavedCamera? savedCamera;
  FollowMode follow = FollowMode.free;

  /// What the map shows right now (set by the map screen), for "This region" downloads.
  GeoBounds? viewBounds;

  /// Set by the catalogue to ask the map screen for a drawn area for this layer; the screen clears it.
  String? drawRequest;

  /// Set when the catalogue has no base map to draw (the first start, before the catalogue was ever fetched, with no
  /// connection). The map screen says so instead of showing a blank map.
  String? get baseProblem {
    if (!engine.ready) return null;
    if (activeDefinitions.any((d) => d.isBase)) return null;
    return 'No base map yet. Connect once to get the catalogue.';
  }

  /// The small line about layers that cannot draw here and now, or null.
  String? notice;
  File? _file;
  Map<String, dynamic>? _template;
  Map<String, dynamic>? _protomapsTemplate;
  Timer? _saveTimer;
  int _coverageSeq = 0;

  Future<void> init() async {
    final dir = settingsDirOverride ?? await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    _file = File('${dir.path}/maps.json');
    try {
      if (_file!.existsSync()) {
        final j = jsonDecode(_file!.readAsStringSync()) as Map<String, dynamic>;
        _hadSettings = true;
        _enabled
          ..clear()
          ..addAll((j['enabled'] as List).cast<String>());
        _opacity
          ..clear()
          ..addAll({for (final e in (j['opacity'] as Map).entries) e.key as String: (e.value as num).toDouble()});
        final defs = j['definitions'];
        if (defs is Map) _definitions..clear()..addAll({for (final e in defs.entries) e.key as String: e.value == true});
        final c = j['camera'];
        if (c is Map) {
          savedCamera = SavedCamera((c['lat'] as num).toDouble(), (c['lon'] as num).toDouble(), (c['zoom'] as num).toDouble());
        }
      }
    } catch (_) {}
    engine.addListener(_onEngine);
    await _startEngine();
  }

  Future<void> _startEngine() async {
    await engine.start();
    // The system refuses the layers' server socket: network access is off for the app.
    needsNetworkAccess = engine.blockedByPermission;
    if (needsNetworkAccess) {
      notifyListeners();
      return;
    }
    if (!_hadSettings) {
      _enabled.addAll([for (final l in activeDefinitions) if (l.defaultOn) l.id]);
    } else {
      // A base map that was saved as on but whose definition is now off (the default base map changed): fall back
      // to the default one rather than opening on no map.
      final gone = [for (final id in _enabled) if (engine.layer(id) case final d? when d.isBase && !isDefinitionEnabled(d)) id];
      if (gone.isNotEmpty) {
        _enabled.removeAll(gone);
        _enabled.addAll([for (final l in activeDefinitions) if (l.isBase && l.defaultOn) l.id]);
      }
    }
    notifyListeners();
  }

  void _onEngine() => notifyListeners();

  /// Called when the app comes back to the screen (for example from the phone's settings).
  Future<void> recheckNetwork() async {
    if (!needsNetworkAccess) return;
    await _startEngine();
    if (!needsNetworkAccess) networkRefused = false;
  }

  /// The button on the map screen: asks the system for network access, then starts the layers again.
  Future<void> allowNetwork() async {
    await _network.request();
    await _startEngine();
    networkRefused = needsNetworkAccess;
    notifyListeners();
  }

  // ---- definitions and region downloads -------------------------------------------------------------------

  /// Definitions the user switched on or off (Advanced); the rest follow the definition's own default.
  final Map<String, bool> _definitions = {};

  bool isDefinitionEnabled(LayerDef d) => _definitions[d.id] ?? d.enabledByDefault;

  /// Advanced: a definition that is off stays in the catalogue but is not offered or drawn.
  void setDefinitionEnabled(String id, bool on) {
    _definitions[id] = on;
    if (!on) _enabled.remove(id);
    _save();
    notifyListeners();
  }

  /// The definitions in use, in the catalogue's order.
  List<LayerDef> get activeDefinitions => [for (final l in engine.layers) if (isDefinitionEnabled(l)) l];

  /// The layers the catalogue and the layer sheet show: one per layer, however many region cuts the catalogue
  /// holds of it. The card is the broadest cut; a download takes the most specific cut that covers the area.
  List<LayerDef> get catalogueLayers {
    final cards = <String, LayerDef>{};
    for (final l in activeDefinitions) {
      if (l.kind == LayerKind.elevation) continue; // feeds hillshade and contours, never listed or drawn
      final known = cards[l.groupKey];
      if (known == null || l.coverageSize > known.coverageSize) cards[l.groupKey] = l;
    }
    return cards.values.toList();
  }

  /// The card's layer and the region cuts of it.
  List<LayerDef> groupOf(LayerDef card) => [for (final l in activeDefinitions) if (l.groupKey == card.groupKey) l];

  /// The definition a download of [card] for [area] uses: the most specific cut whose coverage holds the whole
  /// area (for example an Idaho extract), else the card itself.
  LayerDef downloadDefFor(LayerDef card, GeoBounds area) {
    LayerDef best = card;
    for (final l in groupOf(card)) {
      if (l.covers(area) && l.coverageSize < best.coverageSize) best = l;
    }
    return best;
  }

  List<DownloadedArea> areasOfCard(LayerDef card) => [for (final l in groupOf(card)) ...engine.areasOf(l.id)];

  int storageOfCard(LayerDef card) => groupOf(card).fold(0, (s, l) => s + engine.storageOf(l.id));

  // ---- layers -------------------------------------------------------------------------------------------

  bool isOn(String id) => _enabled.contains(id);

  double opacityOf(String id) => _opacity[id] ?? 1;

  void setOn(String id, bool on) {
    final def = engine.layer(id);
    if (def == null || !isDefinitionEnabled(def)) return;
    if (on) {
      // One base map at a time.
      if (def.isBase) {
        for (final l in engine.layers) {
          if (l.isBase) _enabled.remove(l.id);
        }
      }
      _enabled.add(id);
    } else {
      _enabled.remove(id);
    }
    _save();
    notifyListeners();
  }

  void setOpacity(String id, double v) {
    _opacity[id] = v.clamp(0.1, 1.0);
    _save();
    notifyListeners();
  }

  /// The layers to draw, bottom first (the catalogue's order).
  List<StyleLayerUse> get uses => [
        for (final l in activeDefinitions)
          if (_enabled.contains(l.id)) StyleLayerUse(l, opacityOf(l.id)),
      ];

  /// Credit lines of what is on screen, short enough for the strip on the map (the credits sheet has the full
  /// text and the licences). A long credit is cut after its first sentence.
  List<String> get attributions {
    final seen = <String>{};
    String credit(LayerDef d) {
      final a = shortAttribution(d.attribution);
      // The Protomaps layout is credited whatever the catalogue's own line says.
      return d.isBase && d.layout == 'protomaps-v4' && !a.contains('Protomaps') ? '$a · Protomaps' : a;
    }

    return [
      for (final u in uses)
        if (u.def.attribution.isNotEmpty && seen.add(credit(u.def))) credit(u.def),
    ];
  }

  /// A key that changes whenever the style has to be built again.
  String get styleKey => [
        for (final u in uses) '${u.def.id}:${u.opacity.toStringAsFixed(2)}',
        engine.ready ? 'ready' : 'wait',
        for (final l in engine.layers) l.styleSignature,
      ].join(',');

  Future<Map<String, dynamic>> _omt() async => _template ??= await loadOmtTemplate();

  /// The style JSON for the visible layers in [palette].
  Future<String> styleJson(MapPalette palette, String glyphsUrl, {Map<String, dynamic>? template}) async {
    final needsProtomaps = uses.any((u) => u.def.isBase && MapLayout.parse(u.def.raw['layout']) == MapLayout.protomapsV4);
    final style = buildMapStyle(
      palette: palette,
      omtTemplate: template ?? await _omt(),
      protomapsTemplate: needsProtomaps ? (_protomapsTemplate ??= await loadProtomapsTemplate()) : null,
      layers: uses,
      tilesUrl: (d) => engine.tilesUrl(d.id),
      glyphsUrl: glyphsUrl,
    );
    return jsonEncode(style);
  }

  // ---- camera and follow --------------------------------------------------------------------------------

  void setFollow(FollowMode m) {
    if (follow == m) return;
    follow = m;
    notifyListeners();
  }

  void requestDraw(String layerId) {
    drawRequest = layerId;
    notifyListeners();
  }

  void clearDrawRequest() => drawRequest = null;

  void rememberCamera(double lat, double lon, double zoom) {
    savedCamera = SavedCamera(lat, lon, zoom);
    _save();
  }

  // ---- offline notice -----------------------------------------------------------------------------------

  /// Looks at what the map is showing and sets [notice] when a visible layer has no tiles here and there is
  /// no connection. Never a broken blank: the base colour stays and this says why.
  Future<void> checkCoverage(GeoBounds view, int zoom) async {
    final seq = ++_coverageSeq;
    await engine.refreshOnline();
    String? text;
    if (!engine.online) {
      final missing = <LayerDef>[];
      for (final u in uses) {
        if (u.def.kind == LayerKind.basemap || await engine.hasTiles(u.def.id, view, zoom)) continue;
        missing.add(u.def);
      }
      // The base map first: without it nothing else matters.
      if (uses.any((u) => u.def.kind == LayerKind.basemap) && !await _hasBase(view, zoom)) {
        text = uses.firstWhere((u) => u.def.isBase).def.missingNotice;
      } else if (missing.isNotEmpty) {
        text = _join(missing);
      }
    }
    if (seq != _coverageSeq) return;
    if (text != notice) {
      notice = text;
      notifyListeners();
    }
  }

  Future<bool> _hasBase(GeoBounds view, int zoom) async {
    for (final u in uses) {
      if (u.def.isBase) return engine.hasTiles(u.def.id, view, zoom);
    }
    return true;
  }

  static String _join(List<LayerDef> m) {
    if (m.length == 1) return m.first.missingNotice;
    final names = m.map((l) => l.title).toList();
    final list = names.length == 2 ? '${names[0]} and ${names[1]}' : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
    return '$list need a connection or a download here';
  }

  // ---- saving -------------------------------------------------------------------------------------------

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _write);
  }

  /// Writes the choices now (they are otherwise written a moment after the last change).
  Future<void> flush() async {
    _saveTimer?.cancel();
    await _write();
  }

  Future<void> _write() async {
    try {
      final f = _file;
      if (f == null) return;
      await writeStringAtomic(f, jsonEncode({
        'enabled': _enabled.toList(),
        'opacity': _opacity,
        'definitions': _definitions,
        if (savedCamera != null)
          'camera': {'lat': savedCamera!.lat, 'lon': savedCamera!.lon, 'zoom': savedCamera!.zoom},
      }));
    } catch (_) {}
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    engine.removeListener(_onEngine);
    engine.dispose();
    super.dispose();
  }
}
