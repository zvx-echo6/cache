import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../location/coords.dart';
import '../location/location_service.dart';
import '../location/position_source.dart';
import '../maps/geo.dart';
import '../maps/maps_state.dart';
import '../maps/palette/map_palette.dart';
import '../maps/style/style_generator.dart';
import '../maps/ui/area_draw.dart';
import '../maps/ui/download_sheet.dart';
import '../maps/ui/layer_sheet.dart';
import '../maps/ui/map_assets.dart';
import '../maps/ui/map_widgets.dart';
import '../theme.dart';

/// The Maps tab: a full-screen map with the phone's position, follow and north-up controls, a scale bar,
/// credits, and a layer button. The style comes from the one style generator and the active theme's palette.
class MapsScreen extends StatefulWidget {
  const MapsScreen({super.key, required this.location, required this.maps, required this.themeId});

  final LocationService location;
  final MapsState maps;
  final CacheThemeId themeId;

  @override
  State<MapsScreen> createState() => _MapsScreenState();
}

class _MapsScreenState extends State<MapsScreen> {
  MapLibreMapController? _controller;
  String? _initialStyle;
  String? _glyphs;
  String? _appliedKey;
  bool _styleReady = false;
  Timer? _restyleTimer;
  Timer? _idleTimer;

  double _lat = 39.8;
  double _lon = -98.6;
  double _zoom = 3;
  double _bearing = 0;
  double? _lastHeading;
  Offset? _downAt;

  String? _drawFor;
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onResume: () => maps.recheckNetwork());

  MapsState get maps => widget.maps;
  LocationService get location => widget.location;
  MapPalette get _palette => mapPaletteFor(widget.themeId);
  String get _key => '${widget.themeId.name}|${maps.styleKey}';

  @override
  void initState() {
    super.initState();
    maps.addListener(_onMaps);
    location.addListener(_onLocation);
    _lifecycle;
    final c = maps.savedCamera;
    if (c != null) {
      _lat = c.lat;
      _lon = c.lon;
      _zoom = c.zoom;
    }
    _prepare();
  }

  @override
  void didUpdateWidget(MapsScreen old) {
    super.didUpdateWidget(old);
    if (old.themeId != widget.themeId) _scheduleRestyle();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    maps.removeListener(_onMaps);
    location.removeListener(_onLocation);
    _restyleTimer?.cancel();
    _idleTimer?.cancel();
    super.dispose();
  }

  /// Waits for the layer engine and the shipped fonts, then makes the first style.
  Future<void> _prepare() async {
    try {
      _glyphs = await MapAssets.glyphsUrl();
    } catch (_) {
      _glyphs = null;
    }
    _tryFirstStyle();
  }

  Future<void> _tryFirstStyle() async {
    if (_initialStyle != null || !maps.engine.ready || _glyphs == null) return;
    final key = _key;
    final json = await maps.styleJson(_palette, _glyphs!);
    if (!mounted) return;
    setState(() {
      _initialStyle = json;
      _appliedKey = key;
    });
  }

  void _onMaps() {
    if (!mounted) return;
    _tryFirstStyle();
    if (_initialStyle != null && _key != _appliedKey) _scheduleRestyle();
    final want = maps.drawRequest;
    if (want != null && _drawFor == null) {
      maps.clearDrawRequest();
      setState(() => _drawFor = want);
    }
    setState(() {});
  }

  /// A change of layers, opacity or theme builds the style again, once the changes have settled.
  void _scheduleRestyle() {
    _restyleTimer?.cancel();
    _restyleTimer = Timer(const Duration(milliseconds: 250), _restyle);
  }

  Future<void> _restyle() async {
    final c = _controller;
    if (c == null || _glyphs == null || !maps.engine.ready) return;
    final key = _key;
    final json = await maps.styleJson(_palette, _glyphs!);
    if (!mounted) return;
    _appliedKey = key;
    _styleReady = false;
    await c.setStyle(json);
  }

  // ---- map events ---------------------------------------------------------------------------------------

  void _onMapCreated(MapLibreMapController c) => _controller = c;

  Future<void> _onStyleLoaded() async {
    final c = _controller;
    if (c == null) return;
    _styleReady = true;
    try {
      final p = _palette;
      await c.addImage(kHeadingImage, await MapAssets.headingMarker(p['position'], p['positionRing']));
    } catch (_) {}
    await _pushPosition();
    _afterCameraSettles();
  }

  void _onCameraMove(CameraPosition p) {
    _lat = p.target.latitude;
    _lon = p.target.longitude;
    _zoom = p.zoom;
    if ((_bearing - p.bearing).abs() > 0.5 || (p.bearing != 0 && _bearing == 0) || (p.bearing == 0 && _bearing != 0)) {
      setState(() => _bearing = p.bearing);
    } else {
      _bearing = p.bearing;
    }
    // The scale bar follows the camera.
    if (mounted) setState(() {});
  }

  void _onCameraIdle() {
    final c = _controller;
    final p = c?.cameraPosition;
    if (p != null) maps.rememberCamera(p.target.latitude, p.target.longitude, p.zoom);
    _afterCameraSettles();
  }

  void _afterCameraSettles() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(milliseconds: 400), () async {
      final c = _controller;
      if (c == null || !mounted || !_styleReady) return;
      try {
        final b = await c.getVisibleRegion();
        final view = GeoBounds(
          south: b.southwest.latitude,
          west: b.southwest.longitude,
          north: b.northeast.latitude,
          east: b.northeast.longitude,
        );
        maps.viewBounds = view;
        await maps.checkCoverage(view, _zoom.floor());
      } catch (_) {}
    });
  }

  // ---- position -----------------------------------------------------------------------------------------

  void _onLocation() {
    if (!mounted) return;
    _pushPosition();
    final fix = location.fix;
    if (fix != null && maps.follow != FollowMode.free) _followTo(fix);
    setState(() {});
  }

  Future<void> _pushPosition() async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    final fix = location.fix;
    final features = <Map<String, dynamic>>[];
    if (fix != null) {
      features.add({
        'type': 'Feature',
        'geometry': {
          'type': 'Polygon',
          'coordinates': [circleRing(fix.lat, fix.lon, fix.accuracyM)],
        },
        'properties': <String, dynamic>{},
      });
      final heading = fix.heading ?? _lastHeading;
      if (fix.heading != null) _lastHeading = fix.heading;
      features.add({
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [fix.lon, fix.lat],
        },
        'properties': {'heading': ?heading},
      });
    }
    try {
      await c.setGeoJsonSource(kPositionSource, {'type': 'FeatureCollection', 'features': features});
    } catch (_) {}
  }

  Future<void> _followTo(Fix fix) async {
    final c = _controller;
    if (c == null) return;
    final bearing = maps.follow == FollowMode.headingUp ? (fix.heading ?? _lastHeading ?? _bearing) : 0.0;
    await c.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(
        target: LatLng(fix.lat, fix.lon),
        zoom: math.max(_zoom, 14),
        bearing: bearing,
      )),
      duration: const Duration(milliseconds: 400),
    );
  }

  /// The polite ask shown before the system prompt (never on launch, only when the user taps for location).
  Future<bool> _explain() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use your location?'),
        content: const Text(
          'Cache uses your location to show where you are and to answer questions about places near you. '
          'It stays on this phone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
        ],
      ),
    );
    return yes == true;
  }

  Future<void> _locate() async {
    if (location.fix == null) {
      final ok = await location.request(explain: _explain);
      if (!ok) {
        if (mounted) _problemSnack();
        return;
      }
      maps.setFollow(FollowMode.follow);
      if (location.fix != null) await _followTo(location.fix!);
      return;
    }
    final next = switch (maps.follow) {
      FollowMode.free => FollowMode.follow,
      FollowMode.follow => FollowMode.headingUp,
      FollowMode.headingUp => FollowMode.follow,
    };
    maps.setFollow(next);
    await _followTo(location.fix!);
  }

  void _problemSnack() {
    final text = switch (location.problem) {
      LocationProblem.off => 'Location is off. Switch on "Show my position" in Layers.',
      LocationProblem.permissionDenied => 'Cache was not allowed to read your location.',
      LocationProblem.permissionBlocked => 'Location is blocked for Cache. Allow it in the phone\'s settings.',
      LocationProblem.serviceOff => 'Your phone\'s location is switched off.',
      LocationProblem.noFix => 'Could not get a position yet. Try again outdoors.',
      null => 'No position yet.',
    };
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(text),
      action: switch (location.problem) {
        LocationProblem.permissionBlocked => SnackBarAction(label: 'Settings', onPressed: location.openAppSettings),
        LocationProblem.serviceOff => SnackBarAction(label: 'Settings', onPressed: location.openLocationSettings),
        _ => null,
      },
    ));
  }

  Future<void> _northUp() async {
    if (maps.follow == FollowMode.headingUp) maps.setFollow(FollowMode.follow);
    await _controller?.animateCamera(CameraUpdate.bearingTo(0), duration: const Duration(milliseconds: 300));
  }

  // ---- drawing an area ----------------------------------------------------------------------------------

  Future<void> _useDrawn(Rect r) async {
    final c = _controller;
    final layerId = _drawFor;
    if (c == null || layerId == null) return;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    // Screen points to degrees; the corners of a turned map give the box that holds the whole rectangle.
    final corners = <LatLng>[];
    for (final o in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      corners.add(await c.toLatLng(math.Point<num>(o.dx * ratio, o.dy * ratio)));
    }
    final lats = corners.map((e) => e.latitude);
    final lons = corners.map((e) => e.longitude);
    final area = GeoBounds(south: lats.reduce(math.min), west: lons.reduce(math.min), north: lats.reduce(math.max), east: lons.reduce(math.max));
    final def = maps.engine.layer(layerId);
    if (!mounted) return;
    setState(() => _drawFor = null);
    if (def != null) {
      // The catalogue screen was closed to draw; its progress shows when it is opened again from Layers.
      await showDownloadConfirm(context, maps, def, area, 'Drawn area');
    }
  }

  // ---- credits ------------------------------------------------------------------------------------------

  void _showCredits() {
    final k = context.t;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      builder: (ctx) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shrinkWrap: true,
          children: [
            Text('Map credits', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            for (final u in maps.uses) ...[
              Text(u.def.title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
              Text(u.def.attribution, style: TextStyle(fontSize: 15, color: k.text)),
              Text(u.def.licence, style: TextStyle(fontSize: 14, color: k.secondary)),
              const SizedBox(height: 12),
            ],
            Text('Map data © OpenStreetMap contributors, ODbL 1.0 (openstreetmap.org/copyright).',
                style: TextStyle(fontSize: 14, color: k.secondary)),
            const SizedBox(height: 8),
            Text(
              maps.uses.any((u) => u.def.isBase && u.def.layout == 'protomaps-v4')
                  ? 'Base map: Protomaps basemap tiles and the @protomaps/basemaps style layers (BSD-3-Clause). '
                      'Map fonts: Noto Sans, SIL Open Font License 1.1.'
                  : 'Map style derived from OpenFreeMap Liberty, OSM Bright and Mapbox Open Styles (BSD-3-Clause code, CC BY 4.0 design). '
                      'Map fonts: Noto Sans, SIL Open Font License 1.1.',
              style: TextStyle(fontSize: 14, color: k.secondary),
            ),
          ],
        ),
      ),
    );
  }

  // ---- build --------------------------------------------------------------------------------------------

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(const SnackBar(content: Text('Copied')));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final style = _initialStyle;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: style == null ? _waiting(context) : _mapStack(context, style, k),
    );
  }

  Widget _waiting(BuildContext context) {
    final k = context.t;
    final problem = maps.engine.problem;
    final Widget body;
    if (maps.needsNetworkAccess) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.public_off, size: 40, color: k.secondary),
          const SizedBox(height: 16),
          Text('Maps need network access',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            maps.networkRefused
                ? 'Network access is switched off for Cache. Allow it in the settings of this phone to see the map.'
                : 'Cache streams map tiles when you are online and keeps downloaded areas for when you are not. '
                    'The map cannot start without network access.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: k.secondary),
          ),
          const SizedBox(height: 16),
          if (maps.networkRefused)
            FilledButton(onPressed: location.openAppSettings, child: const Text('Open settings'))
          else
            FilledButton(onPressed: maps.allowNetwork, child: const Text('Allow')),
        ],
      );
    } else if (problem != null) {
      body = Text(problem, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, color: k.secondary));
    } else {
      body = const CircularProgressIndicator();
    }
    return SafeArea(child: Center(child: Padding(padding: const EdgeInsets.all(24), child: body)));
  }

  Widget _mapStack(BuildContext context, String style, CacheTokens k) {
    final fix = location.fix;
    final follow = maps.follow;
    final drawing = _drawFor != null;
    final drawDef = drawing ? maps.engine.layer(_drawFor!) : null;
    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            // A finger moving on the map while it follows the phone means the user wants to look elsewhere.
            onPointerDown: (e) => _downAt = e.position,
            onPointerMove: (e) {
              final d = _downAt;
              if (d != null && (e.position - d).distance > 12 && maps.follow != FollowMode.free) {
                maps.setFollow(FollowMode.free);
              }
            },
            child: MapLibreMap(
              styleString: style,
              initialCameraPosition: CameraPosition(target: LatLng(_lat, _lon), zoom: _zoom),
              onMapCreated: _onMapCreated,
              onStyleLoadedCallback: _onStyleLoaded,
              onCameraMove: _onCameraMove,
              onCameraIdle: _onCameraIdle,
              trackCameraPosition: true,
              compassEnabled: false,
              tiltGesturesEnabled: false,
              logoEnabled: false,
              // Credits are shown by the app (below), so the SDK's own button is moved out of sight.
              attributionButtonMargins: const math.Point(-200, -200),
              myLocationEnabled: false,
              rotateGesturesEnabled: true,
            ),
          ),
        ),
        if (!drawing && maps.baseProblem != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: NoticePill(text: maps.baseProblem!),
            ),
          ),
        if (!drawing) ...[
          if (fix != null)
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _coordsChip(context, fix),
                ),
              ),
            ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MapButton(
                      icon: Icons.layers_outlined,
                      tooltip: 'Layers',
                      onPressed: () => showLayerSheet(context, maps, location),
                    ),
                    const SizedBox(height: 12),
                    MapButton(
                      icon: switch (follow) {
                        FollowMode.free => fix == null ? Icons.location_searching : Icons.my_location,
                        FollowMode.follow => Icons.my_location,
                        FollowMode.headingUp => Icons.navigation_outlined,
                      },
                      tooltip: switch (follow) {
                        FollowMode.free => 'Find me',
                        FollowMode.follow => 'Following you, north up. Tap to turn with your heading',
                        FollowMode.headingUp => 'Following you, heading up. Tap for north up',
                      },
                      active: follow != FollowMode.free,
                      onPressed: _locate,
                    ),
                    if (_bearing.abs() > 0.5 || follow == FollowMode.headingUp) ...[
                      const SizedBox(height: 12),
                      MapButton(
                        icon: Icons.navigation,
                        tooltip: 'North up',
                        onPressed: _northUp,
                        child: CompassNeedle(bearing: _bearing),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (maps.notice != null) ...[
                      Center(child: NoticePill(text: maps.notice!)),
                      const SizedBox(height: 8),
                    ],
                    ScaleBarWidget(lat: _lat, zoom: _zoom),
                    const SizedBox(height: 6),
                    AttributionChip(lines: maps.attributions, onTap: _showCredits),
                  ],
                ),
              ),
            ),
          ),
        ],
        if (drawing)
          AreaDrawOverlay(
            layerTitle: drawDef?.title ?? 'this layer',
            onUse: _useDrawn,
            onCancel: () => setState(() => _drawFor = null),
          ),
      ],
    );
  }

  Widget _coordsChip(BuildContext context, Fix fix) {
    final k = context.t;
    final text = formatDecimal(fix.lat, fix.lon);
    return Semantics(
      button: true,
      label: 'Your position $text. Tap to copy',
      child: GestureDetector(
        onTap: () => _copy(text),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: mapPanel(context, radius: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text)),
              Text('Within ${fix.accuracyM.round()} m', style: TextStyle(fontSize: 13, color: k.secondary)),
            ],
          ),
        ),
      ),
    );
  }
}
