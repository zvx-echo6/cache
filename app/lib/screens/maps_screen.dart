import 'dart:async';
import 'dart:math' as math;

import 'package:cache_search/cache_search.dart' show MapPlace, MapRoute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../location/coords.dart';
import '../linux_ui.dart';
import '../location/location_service.dart';
import '../location/location_web_ui.dart';
import '../location/position_source.dart';
import '../maps/geo.dart';
import '../maps/maps_state.dart';
import '../maps/palette/map_palette.dart';
import '../maps/style/style_generator.dart';
import '../maps/ui/area_draw.dart';
import '../regions/region_catalogue.dart';
import '../regions/ui/region_actions.dart';
import '../maps/ui/layer_sheet.dart';
import '../maps/ui/map_assets.dart';
import '../maps/ui/map_widgets.dart';
import '../maps/measure.dart';
import '../maps/ui/ring_menu.dart';
import '../maps/user_layers.dart';
import '../nav/elevation/route_elevation.dart';
import '../nav/guidance_camera.dart';
import '../nav/overview/overview_camera.dart';
import '../nav/overview/route_overview.dart';
import '../nav/ui/elevation_dock.dart';
import '../nav/ui/elevation_panel.dart';
import '../nav/nav_geojson.dart';
import '../notebook/map_icons.dart';
import '../notebook/notebook_map.dart';
import '../notebook/pin_image.dart';
import '../notebook/place_style.dart';
import '../notebook/notebook_model.dart';
import '../notebook/notebook_state.dart';
import '../notebook/notebook_text.dart';
import '../nav/nav_state.dart';
import '../nav/ui/guidance_panels.dart';
import '../browse/place_about.dart';
import '../layout/adaptive.dart' show kMapSideWidth, kSideCardWidth, showFittedSheet;
import '../nav/ui/place_card.dart';
import '../maps/ui/repeater_card.dart';
import '../nav/ui/route_panel.dart';
import '../nav/ui/search_panel.dart';
import '../regions/regions_state.dart';
import '../theme.dart';

/// The Maps tab: a full-screen map with the phone's position, follow and north-up controls, a scale bar,
/// credits, and a layer button; one search bar; a place card; directions and turn-by-turn guidance. The style comes from the
/// one style generator and the active theme's palette.
class MapsScreen extends StatefulWidget {
  const MapsScreen({super.key, required this.location, required this.maps, required this.nav, required this.themeId, this.glyphsLoader, this.regions, this.notebooks, this.onOpenEntry, this.onNewEntryAt, this.userLayers, this.onOpenRepeaterList, this.about, this.elevation, this.snapshotter});

  /// The route's elevation profile; null: worked out from the layer engine's elevation tiles (tests give their own).
  final RouteElevation? elevation;

  /// Renders the whole-route picture; null: the app's native snapshotter (tests give their own).
  final RouteSnapshotter? snapshotter;

  /// "Open in notebook" on a repeater's card: its list notebook at its row; null leaves the button out.
  final void Function(Repeater repeater)? onOpenRepeaterList;

  /// "Read about it" on a place card (the place's Wikipedia article); null leaves it out.
  final PlaceAbout? about;

  /// Notebooks whose entries have places: drawn as pins and listed under "My layers"; null leaves them out.
  final NotebookState? notebooks;

  /// A notebook pin's Open.
  final void Function(NbEntry entry)? onOpenEntry;

  /// Repeater lists and the lines and areas of imported files: drawn, and listed under "My layers"; null leaves them out.
  final UserLayersState? userLayers;

  /// The ring menu's Save: a new entry of [book] at [at], in that notebook's full entry form.
  final void Function(Notebook book, NbPlace at)? onNewEntryAt;

  final LocationService location;
  final MapsState maps;

  /// Regions and downloads, offered from the layer sheet; null in tests that do not need it.
  final RegionsState? regions;
  final NavState nav;
  final CacheThemeId themeId;

  /// Tests can avoid filesystem font setup; production uses the existing shipped fonts.
  @visibleForTesting
  final Future<String> Function()? glyphsLoader;

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

  /// The map's size on the screen (for where the position sits while guiding).
  Size _mapSize = Size.zero;

  // ---- guidance: the elevation panel and the route mini map ----

  late final RouteElevation _elevation = widget.elevation ?? RouteElevation(loader: tileServerElevationLoader(maps.engine));
  RouteSnapshotter get _snapshotter => widget.snapshotter ?? const ChannelRouteSnapshotter();

  /// The style the live map has (the whole-route picture is rendered from it).
  String? _styleJson;

  /// Swapped: the whole-route picture fills the screen and the live map is the small one in the corner.
  bool _swapped = false;

  /// The whole-route pictures: the corner's, and the full screen's (made the first time it is swapped), with what they were made
  /// for (route, theme and style, size, pixel ratio).
  OverviewPicture? _insetPicture;
  OverviewPicture? _fullPicture;
  String? _insetFor;
  String? _fullFor;

  /// The position for the dot on the picture; it follows every fix, and the picture draws it by the distance rule.
  final ValueNotifier<({double lat, double lon, double? heading})?> _overviewPosition = ValueNotifier(null);

  final GlobalKey _stackKey = GlobalKey();
  final GlobalKey _insetKey = GlobalKey();

  /// Where the corner inset is in the screen's stack (the live map goes there while swapped), and the stack's size.
  Rect? _insetRect;
  Size _stackSize = Size.zero;

  /// Drawing an area to download as a region.
  bool _drawing = false;
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onResume: () => maps.recheckNetwork());

  MapsState get maps => widget.maps;
  NavState get nav => widget.nav;
  String? _navSig;
  String? _fitFor;
  String? _focusFor;
  LocationService get location => widget.location;
  MapPalette get _palette => mapPaletteFor(widget.themeId);
  String get _key => '${widget.themeId.name}|${maps.styleKey}';

  @override
  void initState() {
    super.initState();
    maps.addListener(_onMaps);
    location.addListener(_onLocation);
    nav.addListener(_onNav);
    widget.notebooks?.addListener(_pushNotebooks);
    widget.notebooks?.addListener(_notebooksChanged);
    widget.userLayers?.addListener(_pushUser);
    widget.userLayers?.selectedRepeater.addListener(_onRepeater);
    _elevation.addListener(_onElevation);
    _lifecycle;
    // Maps opens on the phone's position when it is known (at the remembered zoom); the remembered view is for when it is
    // not (no fix yet, location off). The search box searches around what the map shows, so it starts there too.
    final c = maps.savedCamera;
    if (c != null) {
      _lat = c.lat;
      _lon = c.lon;
      _zoom = c.zoom;
    }
    final fix = location.fix;
    if (fix != null) {
      _lat = fix.lat;
      _lon = fix.lon;
      if (c == null) _zoom = 14;
    }
    if (fix != null || c != null) nav.setMapCentre(_lat, _lon);
    if (fix != null) _overviewPosition.value = (lat: fix.lat, lon: fix.lon, heading: fix.heading);
    // A draw asked for before this screen was first built (the Regions sheet opened from Home) starts it now.
    if (maps.drawRequest) {
      maps.clearDrawRequest();
      _drawing = widget.regions != null;
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
    nav.removeListener(_onNav);
    widget.notebooks?.removeListener(_pushNotebooks);
    widget.notebooks?.removeListener(_notebooksChanged);
    widget.userLayers?.removeListener(_pushUser);
    widget.userLayers?.selectedRepeater.removeListener(_onRepeater);
    _elevation.removeListener(_onElevation);
    if (widget.elevation == null) _elevation.dispose();
    _overviewPosition.dispose();
    _insetPicture?.image.dispose();
    _fullPicture?.image.dispose();
    _restyleTimer?.cancel();
    _idleTimer?.cancel();
    super.dispose();
  }

  /// Waits for the layer engine and the shipped fonts, then makes the first style.
  Future<void> _prepare() async {
    try {
      _glyphs = await (widget.glyphsLoader?.call() ?? MapAssets.glyphsUrl());
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
      _styleJson = json;
      _appliedKey = key;
    });
  }

  void _onMaps() {
    if (!mounted) return;
    _tryFirstStyle();
    if (_initialStyle != null && _key != _appliedKey) _scheduleRestyle();
    if (maps.drawRequest && !_drawing) {
      maps.clearDrawRequest();
      setState(() => _drawing = widget.regions != null);
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
    _styleJson = json;
    await c.setStyle(json);
  }

  // ---- map events ---------------------------------------------------------------------------------------

  void _onMapCreated(MapLibreMapController c) {
    _controller = c;
    _keepOnline(c);
  }

  /// MapLibre stops asking for tiles when the phone has no connection, even for the app's own tile server on this
  /// phone (127.0.0.1), which is the one place the map reads from. Telling it it is connected keeps the downloaded
  /// areas drawing in airplane mode; whether the layers may use the network is the layer engine's own setting.
  Future<void> _keepOnline(MapLibreMapController c) async {
    try {
      await c.forceOnlineMode();
    } catch (_) {}
  }

  Future<void> _onStyleLoaded() async {
    final c = _controller;
    if (c == null) return;
    _styleReady = true;
    _keepOnline(c);
    final tactical = widget.themeId == CacheThemeId.tactical;
    final images = _pinImages = PinImages((name, png) => c.addImage(name, png), maps.pinStyle, tactical: tactical);
    try {
      await images.ensure(kRepeaterIcon, mapIcon(kRepeaterIcon).icon, repeaterTint(tactical: tactical));
    } catch (_) {}
    try {
      final p = _palette;
      await c.addImage(kHeadingImage, await MapAssets.headingMarker(p['position'], p['positionRing']));
    } catch (_) {}
    await _pushPosition();
    _navSig = null;
    await _pushNav();
    _notebookSig = -1;
    await _pushNotebooks();
    _userSig = -1;
    await _pushUser();
    await _pushMeasure();
    _onNav(); // A route may have been loaded before this screen/listener existed.
    _afterCameraSettles();
  }

  void _onCameraMove(CameraPosition p) {
    _lat = p.target.latitude;
    _lon = p.target.longitude;
    _zoom = p.zoom;
    nav.setMapCentre(_lat, _lon);
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
    final f = location.fix;
    _overviewPosition.value = f == null ? null : (lat: f.lat, lon: f.lon, heading: f.heading ?? _lastHeading);
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
    final guiding = nav.guiding;
    // While guiding and standing still the map keeps pointing along the route.
    final routeBearing = guiding ? nav.progress?.routeBearingDeg.toDouble() : null;
    final bearing = maps.follow == FollowMode.headingUp ? (fix.heading ?? routeBearing ?? _lastHeading ?? _bearing) : 0.0;
    final zoom = math.max(_zoom, guiding ? 16 : 14).toDouble();
    var target = LatLng(fix.lat, fix.lon);
    // Guiding heading-up, the position sits low on the map so more of the road ahead shows (lib/nav/guidance_camera.dart).
    if (guiding && maps.follow == FollowMode.headingUp && !_mapSize.isEmpty && mounted) {
      final side = MediaQuery.sizeOf(context).width >= kSideCardWidth && _measure == null && !_swapped;
      final anchor = guidanceAnchor(_mapSize, side: side, leftInset: MediaQuery.paddingOf(context).left);
      final (lat, lon) = cameraCentreFor(fix.lat, fix.lon, bearing: bearing, zoom: zoom, map: _mapSize, anchor: anchor);
      target = LatLng(lat, lon);
    }
    await c.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(
        target: target,
        zoom: zoom,
        bearing: bearing,
      )),
      duration: Duration(milliseconds: guiding ? 900 : 400),
    );
  }

  // ---- navigation: route, pins, camera --------------------------------------------------------------------

  /// The route and pin sources follow the navigation state.
  Future<void> _pushNav() async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    final sig = '${nav.routes.map((r) => r.routeId).join('+')}|${nav.routeIndex}|${nav.selected?.id}|${nav.searchOpen ? nav.results.map((r) => r.id).join(',') : ''}';
    if (sig == _navSig) return;
    _navSig = sig;
    try {
      await c.setGeoJsonSource(kRouteSource, routeGeoJson(nav.routes, nav.routeIndex));
      await c.setGeoJsonSource(kPinSource, pinGeoJson(nav.selected, nav.searchOpen ? nav.results : const []));
    } catch (_) {}
  }

  void _onNav() {
    if (!mounted) return;
    _pushNav();
    _elevation.request(nav.phase == NavPhase.browsing ? null : nav.route);
    if (!nav.guiding || nav.arrived) {
      _swapped = false;
      if (!nav.guiding) _elevation.setOpen(false);
    }
    final r = nav.route;
    // A new set of routes: show all of the chosen one.
    if (_controller != null && _styleReady && nav.phase == NavPhase.previewing && r != null && _fitFor != r.routeId) {
      _fitFor = r.routeId;
      _fitRoute(r);
    }
    if (nav.phase == NavPhase.browsing) _fitFor = null;
    // A place was chosen: bring it into view.
    final sel = nav.selected;
    if (nav.phase == NavPhase.browsing && sel != null && _focusFor != sel.id) {
      _focusFor = sel.id;
      _focusOn(sel.lat, sel.lon);
    }
    if (sel == null) _focusFor = null;
    setState(() {});
  }

  Future<void> _fitRoute(MapRoute r) async {
    final c = _controller;
    if (c == null || !_styleReady || r.points.length < 2) return;
    maps.setFollow(FollowMode.free); // GPS must not pull an exact preview out of view.
    final b = r.bounds;
    final pad = MediaQuery.sizeOf(context);
    try {
      await c.animateCamera(
        CameraUpdate.newLatLngBounds(LatLngBounds(southwest: LatLng(b[0], b[1]), northeast: LatLng(b[2], b[3])), left: 48, right: 48, top: 120, bottom: math.min(pad.height * 0.5, 420)),
        duration: const Duration(milliseconds: 600),
      );
    } catch (_) {}
  }

  Future<void> _focusOn(double lat, double lon) async {
    final c = _controller;
    if (c == null) return;
    maps.setFollow(FollowMode.free);
    try {
      await c.animateCamera(CameraUpdate.newLatLngZoom(LatLng(lat, lon), math.max(_zoom, 14)), duration: const Duration(milliseconds: 500));
    } catch (_) {}
  }

  // ---- notebook pins -------------------------------------------------------------------------------------

  int _notebookSig = -1;
  List<NbEntry> _pins = const [];

  /// The pin images the loaded style has (a new style has none).
  PinImages? _pinImages;

  /// The notebooks' pins follow their entries and map switches.
  Future<void> _pushNotebooks() async {
    final nb = widget.notebooks;
    final c = _controller;
    if (nb == null || c == null || !_styleReady || nb.revision == _notebookSig) return;
    _notebookSig = nb.revision;
    try {
      await nb.start();
      _pins = await nb.pins();
      // Each pin's image (its style, icon and colour) is drawn once and added to the style; the layer names it per feature.
      final images = _pinImages;
      final names = <String, String>{};
      if (images != null) {
        for (final e in _pins) {
          final look = PinLook.of(e, nb.notebook(e.notebookId), tactical: widget.themeId == CacheThemeId.tactical);
          names[e.id] = await images.ensure(look.icon.id, look.glyph, look.tint);
        }
      }
      await c.setGeoJsonSource(kNotebookSource, notebookPinsGeoJson(_pins, pinImages: names));
    } catch (_) {}
  }

  int _userSig = -1;
  int _notebookSeen = -1;

  /// A notebook's change can change its layer (a file's lines and areas, its map switch): the user layers are read again.
  void _notebooksChanged() {
    final nb = widget.notebooks;
    if (nb == null || nb.revision == _notebookSeen) return;
    _notebookSeen = nb.revision;
    widget.userLayers?.reload();
  }

  /// Repeater lists and imported lines and areas follow their switches.
  Future<void> _pushUser() async {
    final u = widget.userLayers;
    final c = _controller;
    if (u == null || c == null || !_styleReady || u.revision == _userSig) return;
    _userSig = u.revision;
    try {
      await c.setGeoJsonSource(kUserSource, await u.mapGeoJson());
    } catch (_) {}
  }

  /// A tap on a notebook pin opens its card; true when there was one.
  Future<bool> _tapNotebookPin(math.Point<double> point) async {
    final c = _controller;
    if (c == null || widget.notebooks == null || _pins.isEmpty) return false;
    try {
      final hits = await c.queryRenderedFeatures(point, [kNotebookPins], null);
      for (final h in hits) {
        final props = h is Map ? h['properties'] : null;
        final id = props is Map ? props['entry'] : null;
        final e = _pins.where((p) => p.id == id).firstOrNull;
        if (e != null) {
          if (mounted) _notebookCard(e);
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// A tap on a repeater selects it (UserLayersState.selectedRepeater) so its card can open; true when there was one.
  Future<bool> _tapRepeater(math.Point<double> point) async {
    final c = _controller;
    final u = widget.userLayers;
    if (c == null || u == null || u.repeaterLists.isEmpty) return false;
    try {
      final hits = await c.queryRenderedFeatures(point, [kUserRepeaters], null);
      for (final h in hits) {
        final ref = repeaterRef(h is Map ? h['properties'] : null);
        if (ref != null && u.selectRepeater(ref.$1, ref.$2) != null) {
          HapticFeedback.selectionClick();
          // One card at a time: the repeater's replaces a place's.
          if (nav.selected != null) nav.clearSelection();
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// A repeater was chosen: its card shows; one chosen outside the map (its list notebook) is brought into view.
  void _onRepeater() {
    final u = widget.userLayers;
    final r = u?.selectedRepeater.value;
    if (u != null && r != null && u.focusPending) {
      u.focusPending = false;
      if (nav.selected != null) nav.clearSelection();
      if (r.located) _focusOn(r.lat!, r.lon!);
    }
    if (mounted) setState(() {});
  }

  /// The card of the repeater chosen on the map (null when none, or a place card or route is showing).
  Widget? _repeaterCard() {
    final u = widget.userLayers;
    final r = u?.selectedRepeater.value;
    if (u == null || r == null) return null;
    final here = nav.here;
    return RepeaterCard(
      repeater: r,
      distance: repeaterDistance(r, nav.fmt, fromLat: here?.lat ?? _lat, fromLon: here?.lon ?? _lon, fromMapCentre: here == null),
      onClose: u.clearRepeater,
      onDirections: nav.phase != NavPhase.browsing || !r.located
          ? null
          : () {
              u.clearRepeater();
              nav.openDirections(MapPlace.pin(r.lat!, r.lon!, name: r.name));
            },
      onOpenList: widget.onOpenRepeaterList == null ? null : () => widget.onOpenRepeaterList!(r),
    );
  }

  void _notebookCard(NbEntry e) {
    final book = widget.notebooks?.notebook(e.notebookId);
    final place = e.place!;
    showFittedSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(entryTitle(e), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: ctx.t.text)),
              Text([?book?.name, dayText(e.when, now: DateTime.now()), place.display].join(' · '), style: TextStyle(fontSize: 15, color: ctx.t.secondary)),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (widget.onOpenEntry != null)
                    FilledButton(
                      key: const ValueKey('pin-open'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        widget.onOpenEntry!(e);
                      },
                      child: const Text('Open'),
                    ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const ValueKey('pin-directions'),
                    onPressed: nav.phase != NavPhase.browsing
                        ? null
                        : () {
                            Navigator.pop(ctx);
                            nav.select(MapPlace(
                              id: 'notebook:${e.id}',
                              type: 'place',
                              name: entryTitle(e),
                              kind: book?.name ?? '',
                              address: place.label ?? '',
                              lat: place.lat,
                              lon: place.lon,
                              matched: '',
                              formats: const {},
                            ));
                          },
                    child: const Text('Directions'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onMapTap(math.Point<double> point, LatLng at) async {
    final m = _measure;
    if (m != null) {
      HapticFeedback.selectionClick();
      setState(() => m.add(at.latitude, at.longitude));
      await _pushMeasure();
      return;
    }
    if (!nav.searchOpen && await _tapNotebookPin(point)) return;
    if (!nav.searchOpen && await _tapRepeater(point)) return;
    if (nav.searchOpen) {
      nav.closeSearch(clear: false);
    } else if (nav.phase == NavPhase.browsing && nav.selected != null) {
      nav.clearSelection();
    }
  }

  // ---- the ring menu (press and hold on the map) --------------------------------------------------------------

  _Ring? _ring;

  void _onMapLongPress(math.Point<double> point, LatLng at) {
    if (nav.guiding || _measure != null) return;
    HapticFeedback.mediumImpact();
    final ring = _Ring(at: _downAt ?? MediaQuery.sizeOf(context).center(Offset.zero), lat: at.latitude, lon: at.longitude);
    setState(() => _ring = ring);
    _nameRing(ring);
  }

  /// The ring's centre names the spot: the nearest town as the core describes coordinates, when it can.
  Future<void> _nameRing(_Ring ring) async {
    try {
      final r = await nav.backend.search('${ring.lat.toStringAsFixed(6)},${ring.lon.toStringAsFixed(6)}', near: nav.here, limit: 1, meaning: false);
      final c = r.results.where((x) => x.isCoordinates).firstOrNull;
      if (c != null && c.address.isNotEmpty && mounted && identical(_ring, ring)) setState(() => ring.name = c.address);
    } catch (_) {}
  }

  static IconData _bookIcon(Notebook n) => switch (n.template) {
        'places' => Icons.place_outlined,
        'journal' => Icons.edit_note,
        'notes' => Icons.sticky_note_2_outlined,
        _ => n.isLog ? Icons.event_available_outlined : Icons.book_outlined,
      };

  /// The ring's wedges: To here, Save (the Notebooks book icon); after Save, the notebooks, most used first, paged by More.
  List<RingItem> _ringItems(_Ring r) {
    if (!r.notebooks) {
      return [
        const RingItem(id: 'to', label: 'To here', icon: Icons.near_me_outlined),
        const RingItem(id: 'from', label: 'From here', icon: Icons.trip_origin),
        // Add stop only while a route is shown.
        if (nav.phase == NavPhase.previewing) const RingItem(id: 'stop', label: 'Add stop', icon: Icons.add_location_alt_outlined),
        if (widget.notebooks != null && widget.onNewEntryAt != null) const RingItem(id: 'save', label: 'Save', icon: Icons.book_outlined),
        const RingItem(id: 'measure', label: 'Measure', icon: Icons.straighten),
      ];
    }
    final all = [
      for (final n in widget.notebooks?.notebooks ?? const <Notebook>[])
        RingItem(
          id: n.id,
          label: n.name,
          icon: _bookIcon(n),
          leading: SizedBox(
            height: 24,
            child: PinGlyph(icon: mapIconOrTemplate(n.def.icon ?? defaultNotebookIcon(n)).icon, tint: pinTint(context, markerColor(n.def.color).color), style: maps.pinStyle, size: 24),
          ),
        ),
    ];
    return ringPage(all, r.page);
  }

  int _ringPageCount() => ringPages([for (final n in widget.notebooks?.notebooks ?? const <Notebook>[]) RingItem(id: n.id, label: n.name, icon: Icons.book)]);

  void _ringPick(RingItem item) {
    final r = _ring;
    if (r == null) return;
    switch (item.id) {
      case 'to':
        setState(() => _ring = null);
        nav.openDirections(_ringPlace(r));
      case 'from':
        setState(() => _ring = null);
        nav.setFrom(_ringPlace(r));
      case 'stop':
        setState(() => _ring = null);
        nav.addStop(_ringPlace(r));
      case 'measure':
        setState(() {
          _ring = null;
          _measure = MeasureLine(r.lat, r.lon);
        });
        _pushMeasure();
      case 'save':
        widget.notebooks?.start();
        setState(() {
          r.notebooks = true;
          r.page = 0;
        });
      case kRingMore:
        setState(() => r.page = (r.page + 1) % _ringPageCount());
      default:
        final book = widget.notebooks?.notebook(item.id);
        setState(() => _ring = null);
        if (book != null) widget.onNewEntryAt?.call(book, NbPlace(lat: r.lat, lon: r.lon, label: r.name));
    }
  }

  /// The centre: the first ring's opens the spot's coordinate card (the dropped-pin card, with its formats); the notebook ring's
  /// goes back.
  MapPlace _ringPlace(_Ring r) => MapPlace.pin(r.lat, r.lon, name: r.name ?? pinName(r.lat, r.lon), formats: {'decimal': formatDecimal(r.lat, r.lon)});

  // ---- measuring a distance (the ring's Measure) -------------------------------------------------------------

  MeasureLine? _measure;

  Future<void> _pushMeasure() async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    try {
      await c.setGeoJsonSource(kMeasureSource, _measure?.geoJson() ?? const {'type': 'FeatureCollection', 'features': <Object>[]});
    } catch (_) {}
  }

  void _measureDone() {
    setState(() => _measure = null);
    _pushMeasure();
  }

  Widget _measurePanel(BuildContext context, MeasureLine m, CacheTokens k) => MeasurePanel(
        total: nav.fmt.distance(m.totalM),
        points: m.points.length,
        canUndo: m.canUndo,
        onUndo: () {
          setState(m.undo);
          _pushMeasure();
        },
        onDone: _measureDone,
      );

  void _ringBack() {
    final r = _ring;
    if (r == null) return;
    switch (ringCentre(notebooks: r.notebooks, page: r.page)) {
      case RingCentre.coordinates:
        setState(() => _ring = null);
        nav.dropPin(r.lat, r.lon);
      case RingCentre.previousPage:
        setState(() => r.page--);
      case RingCentre.firstRing:
        setState(() => r.notebooks = false);
    }
  }

  Widget _ringOverlay(BuildContext context, _Ring r, CacheTokens k) {
    const size = 232.0;
    final screen = MediaQuery.sizeOf(context);
    final left = (r.at.dx - size / 2).clamp(8.0, math.max(8.0, screen.width - size - 8)).toDouble();
    final top = (r.at.dy - size / 2).clamp(80.0, math.max(80.0, screen.height - size - 8)).toDouble();
    final pages = r.notebooks ? _ringPageCount() : 1;
    final centre = r.notebooks
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.undo, size: 16, color: k.text), const SizedBox(width: 4), Text('Back', style: TextStyle(fontSize: 14, color: k.text))]),
              if (pages > 1) Text('${r.page + 1} of $pages', style: TextStyle(fontSize: 12, color: k.secondary)),
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(r.name ?? 'Here', maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.text)),
              Text(formatDecimal(r.lat, r.lon).replaceAll(', ', ',\n'), textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: k.secondary)),
            ],
          );
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(child: GestureDetector(key: const ValueKey('ring-dismiss'), behavior: HitTestBehavior.opaque, onTap: () => setState(() => _ring = null))),
          Positioned(
            left: left,
            top: top,
            child: RingMenu(key: const ValueKey('ring-menu'), size: size, items: _ringItems(r), onPick: _ringPick, centre: centre, onCentre: _ringBack),
          ),
        ],
      ),
    );
  }

  /// The polite ask shown before the system prompt (never on launch, only when the user taps for location).
  Future<bool> _explain() async {
    if (linuxUi) return showLocationPrePrompt(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use your location?'),
        content: const Text(
          'Cache uses your location to show where you are and to answer questions about places near you. '
          'It stays on this device.',
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
    if (linuxUi) {
      final m = ScaffoldMessenger.of(context);
      m.hideCurrentSnackBar();
      m.showSnackBar(webLocationSnack(location.problem, onHowToAllow: () => showHowToAllow(context), onTryAgain: _locate));
      return;
    }
    final text = switch (location.problem) {
      LocationProblem.off => 'Location is off. Switch on "Show my position" in Layers.',
      LocationProblem.permissionDenied => 'Cache was not allowed to read your location.',
      LocationProblem.permissionBlocked => 'Location is blocked for Cache. Allow it in the device\'s settings.',
      LocationProblem.serviceOff => 'Your device\'s location is switched off.',
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
    final regions = widget.regions;
    if (c == null || regions == null) return;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    // Screen points to degrees; the corners of a turned map give the box that holds the whole rectangle.
    final corners = <LatLng>[];
    for (final o in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      corners.add(await c.toLatLng(math.Point<num>(o.dx * ratio, o.dy * ratio)));
    }
    final lats = corners.map((e) => e.latitude);
    final lons = corners.map((e) => e.longitude);
    final area = GeoBounds(south: lats.reduce(math.min), west: lons.reduce(math.min), north: lats.reduce(math.max), east: lons.reduce(math.max));
    if (!mounted) return;
    setState(() => _drawing = false);
    // The same download pop-up as a region from the list. A drawn area is the one region whose size is worked out on the phone.
    final rec = RegionRecord.drawn(area);
    await openRegionOffer(context, regions, rec, drawnSize: () => drawnSizeOf(context, regions, rec));
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

  // ---- guidance: elevation and the route mini map ------------------------------------------------------

  void _onElevation() {
    if (mounted) setState(() {});
  }

  /// A phone (upright or sideways), as opposed to a tablet or a computer.
  bool get _phone => MediaQuery.sizeOf(context).shortestSide < 600;

  /// The corner inset shows while guiding (on phones and tablets; car screens have their own), and hides while the elevation
  /// panel is pulled up on a phone.
  bool get _insetOn => nav.guiding && !nav.arrived && nav.route != null;
  bool get _insetHidden => _elevation.open && _phone;

  /// The inset's side: 112 on a phone upright, 96 sideways, 160 on a tablet or a computer.
  double get _insetSide {
    final size = MediaQuery.sizeOf(context);
    if (!_phone) return 160;
    return size.width > size.height ? 96 : 112;
  }

  /// Tap on the inset: the whole-route picture and the live close-up change places.
  void _toggleSwap() {
    setState(() => _swapped = !_swapped);
    // The live map changed size: put the position where it belongs on it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final f = location.fix;
      if (mounted && f != null && maps.follow != FollowMode.free) _followTo(f);
    });
  }

  /// The padding of the full-screen picture: the route stays clear of the banner, the card and the buttons.
  EdgeInsets _fullPadding(Size size) {
    final pad = MediaQuery.paddingOf(context);
    if (size.width >= kSideCardWidth) return EdgeInsets.fromLTRB(pad.left + kMapSideWidth + 40, pad.top + 72, pad.right + 76, pad.bottom + 72);
    return EdgeInsets.fromLTRB(32, pad.top + 150, 32, pad.bottom + 210);
  }

  /// Makes the whole-route pictures that are missing or out of date (another route, theme, style, size or pixel ratio). The live
  /// map is not involved: the native snapshotter renders offscreen.
  void _ensurePictures(Size stack) {
    final r = nav.route;
    final style = _styleJson;
    if (!_insetOn || r == null || style == null || r.points.length < 2) return;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final side = _insetSide - 4; // inside the 2-point border
    final b = r.bounds;
    final insetFor = '${r.routeId}|$_key|$side|$ratio';
    if (_insetFor != insetFor) {
      _insetFor = insetFor;
      final cam = OverviewCamera.fit(south: b[0], west: b[1], north: b[2], east: b[3], size: Size(side, side), padding: const EdgeInsets.fromLTRB(14, 16, 14, 16));
      unawaited(_render(style, r, cam, ratio, full: false, sig: insetFor));
    }
    if (_swapped && !stack.isEmpty) {
      final fullFor = '${r.routeId}|$_key|${stack.width.round()}x${stack.height.round()}|$ratio';
      if (_fullFor != fullFor) {
        _fullFor = fullFor;
        final cam = OverviewCamera.fit(south: b[0], west: b[1], north: b[2], east: b[3], size: stack, padding: _fullPadding(stack));
        unawaited(_render(style, r, cam, ratio, full: true, sig: fullFor));
      }
    }
  }

  Future<void> _render(String style, MapRoute r, OverviewCamera cam, double ratio, {required bool full, required String sig}) async {
    OverviewPicture? pic;
    try {
      pic = await _snapshotter.render(styleJson: overviewStyleJson(style, r), camera: cam, pixelRatio: ratio);
    } catch (_) {
      pic = null;
    }
    if (!mounted || (full ? _fullFor : _insetFor) != sig) {
      pic?.image.dispose();
      return;
    }
    // Not made (no native snapshotter here, or it failed): the land colour and the dot show, and it is tried again when the route,
    // the theme or the size changes.
    if (pic == null) return;
    setState(() {
      if (full) {
        _fullPicture?.image.dispose();
        _fullPicture = pic;
      } else {
        _insetPicture?.image.dispose();
        _insetPicture = pic;
      }
    });
  }

  /// Reads where the inset sits after a layout (the live map is moved there while swapped).
  void _measureInset() {
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final box = _insetKey.currentContext?.findRenderObject() as RenderBox?;
    Rect? rect;
    if (stack != null && stack.hasSize) _stackSize = stack.size;
    if (stack != null && box != null && box.hasSize && stack.hasSize) {
      final o = box.localToGlobal(Offset.zero, ancestor: stack);
      rect = o & box.size;
    }
    if (rect != _insetRect && mounted) setState(() => _insetRect = rect);
  }

  /// The corner inset: in its normal state the whole-route picture with the dot; swapped, the frame the live map shows through.
  /// A tap swaps them (the only gesture: the live map in the corner does not pan or zoom).
  Widget _inset(BuildContext context) {
    final k = context.t;
    final side = _insetSide;
    return Semantics(
      button: true,
      label: _swapped ? 'Swap to the close-up' : 'Swap to the whole route',
      child: GestureDetector(
        key: const ValueKey('route-inset'),
        behavior: HitTestBehavior.opaque,
        onTap: _toggleSwap,
        child: SizedBox(
          key: _insetKey,
          width: side,
          height: side,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: k.surface, width: 2),
              boxShadow: _swapped ? null : const [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (!_swapped) RouteOverview(key: const ValueKey('route-overview-inset'), picture: _insetPicture, palette: _palette, position: _overviewPosition, route: nav.route?.points ?? const []),
                  Positioned(
                    left: 5,
                    top: 5,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(color: k.surface, shape: BoxShape.circle, boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 3, offset: Offset(0, 1))]),
                      child: Icon(Icons.open_in_full, size: 14, color: k.text),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The scale bar's latitude and zoom: the picture's while it fills the screen, else the live map's.
  (double, double) get _scaleView {
    final full = _swapped && _insetOn ? _fullPicture ?? _insetPicture : null;
    if (full == null) return (_lat, _zoom);
    final size = _stackSize;
    final cam = full.camera;
    final cover = size.isEmpty ? 1.0 : math.max(size.width / cam.size.width, size.height / cam.size.height);
    return (cam.lat, cam.zoom + math.log(cover) / math.ln2);
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
                ? 'Network access is switched off for Cache. Allow it in the settings of this device to see the map.'
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
    final drawing = _drawing;
    final inset = _insetOn && !drawing && _measure == null;
    final swapped = inset && _swapped;
    if (inset) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _measureInset();
        _ensurePictures(_stackSize);
      });
    }
    // Swapped, the live map (the same widget, so the same map) moves into the inset's frame; hidden with the inset, it is kept
    // but not drawn.
    final corner = swapped ? _insetRect?.deflate(2) : null;
    final hideLive = swapped && (_insetHidden || corner == null);
    return Stack(
      key: _stackKey,
      children: [
        if (swapped)
          Positioned.fill(
            key: const ValueKey('route-overview-full'),
            child: RouteOverview(picture: _fullPicture ?? _insetPicture, palette: _palette, position: _overviewPosition, route: nav.route?.points ?? const [], dotScale: 1.6),
          ),
        Positioned(
          key: const ValueKey('live-map'),
          left: corner?.left ?? 0,
          top: corner?.top ?? 0,
          right: corner == null ? 0 : null,
          bottom: corner == null ? 0 : null,
          width: corner?.width,
          height: corner?.height,
          child: Visibility(
            visible: !hideLive,
            maintainState: true,
            child: ClipRRect(
            borderRadius: BorderRadius.circular(corner == null ? 0 : 16),
            clipBehavior: corner == null ? Clip.none : Clip.antiAlias,
            child: LayoutBuilder(builder: (context, box) {
            _mapSize = box.biggest;
              return Listener(
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
                onMapClick: _onMapTap,
                onMapLongClick: _onMapLongPress,
                trackCameraPosition: true,
                compassEnabled: false,
                tiltGesturesEnabled: false,
                logoEnabled: false,
                // Credits are shown by the app (below), so the SDK's own button is moved out of sight.
                attributionButtonMargins: const math.Point(-200, -200),
                myLocationEnabled: false,
                rotateGesturesEnabled: true,
              ),
            );
          }),
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
        if (!drawing && MediaQuery.sizeOf(context).width >= kSideCardWidth && _measure == null)
          _sideLayers(context, fix, follow)
        else if (!drawing) ...[
          _topLayer(context, fix, follow),
          if (_measure == null) _bottomLayer(context),
        ],
        if (_ring != null && !drawing) _ringOverlay(context, _ring!, k),
        if (_measure != null && !drawing)
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: _measurePanel(context, _measure!, k))),
          ),
        if (drawing)
          AreaDrawOverlay(
            onUse: _useDrawn,
            onCancel: () => setState(() => _drawing = false),
          ),
      ],
    );
  }

  /// The top: the search bar (or the directions header, or the turn banner), and under it the controls.
  Widget _topLayer(BuildContext context, Fix? fix, FollowMode follow) {
    final guiding = nav.guiding;
    final previewing = nav.phase == NavPhase.previewing;
    final Widget top = guiding
        ? GuidanceBanner(nav: nav, fmt: nav.fmt)
        : previewing
            ? DirectionsHeader(nav: nav)
            : NavSearchBar(nav: nav, fmt: nav.fmt, regions: widget.regions);
    final searching = nav.searchOpen && nav.phase == NavPhase.browsing && nav.query.trim().isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + (searching ? MediaQuery.viewInsetsOf(context).bottom : 0)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(child: top),
            if (!previewing && !guiding && nav.fromPlace != null) Padding(padding: const EdgeInsets.only(top: 8), child: _fromChip(context)),
            if (!searching) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (fix != null && !guiding) _coordsChip(context, fix),
                  const Spacer(),
                  _controls(context, fix, follow),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _controls(BuildContext context, Fix? fix, FollowMode follow) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!nav.guiding)
          MapButton(
            icon: Icons.layers_outlined,
            tooltip: 'Layers',
            onPressed: () => showLayerSheet(context, maps, location, regions: widget.regions, notebooks: widget.notebooks, userLayers: widget.userLayers),
          ),
        if (!nav.guiding) const SizedBox(height: 12),
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
    );
  }

  /// The place card, the way to go, the guidance bar or a repeater's card; null when none shows.
  /// [maxHeight]: the room in the map's side column, which the card or the way to go fills before it scrolls.
  Widget? _panel(bool searching, {double? maxHeight}) {
    final sel = nav.selected;
    if (nav.guiding) return GuidanceDock(nav: nav, elevation: _elevation, palette: _palette);
    if (nav.phase == NavPhase.previewing) {
      return RoutePanel(nav: nav, fmt: nav.fmt, maxHeight: maxHeight, elevation: RouteElevationSummary(elevation: _elevation, fmt: nav.fmt, palette: _palette));
    }
    if (sel != null && !searching) return PlaceCard(nav: nav, place: sel, fmt: nav.fmt, onClose: nav.clearSelection, about: widget.about, maxHeight: maxHeight);
    if (!searching && nav.phase == NavPhase.browsing) return _repeaterCard();
    return null;
  }

  /// From [kSideCardWidth] wide (a tablet, a computer's window, a phone held sideways): a column on the left with the search bar
  /// (or the directions header, or the turn banner) and under it the place card or the way to go (the guidance bar at its foot),
  /// scrolling when taller than the room; beside it, over the map, the position and the buttons at the top and the scale and
  /// credits at the foot. Nothing covers anything, and the map stays in view.
  Widget _sideLayers(BuildContext context, Fix? fix, FollowMode follow) {
    final guiding = nav.guiding;
    final previewing = nav.phase == NavPhase.previewing;
    final searching = nav.searchOpen && nav.phase == NavPhase.browsing && nav.query.trim().isNotEmpty;
    final Widget top = guiding
        ? GuidanceBanner(nav: nav, fmt: nav.fmt)
        : previewing
            ? DirectionsHeader(nav: nav)
            : NavSearchBar(nav: nav, fmt: nav.fmt, regions: widget.regions);
    final panel = _panel(searching);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 12, 12, 8 + (searching ? MediaQuery.viewInsetsOf(context).bottom : 0)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: kMapSideWidth,
              child: LayoutBuilder(
                builder: (context, c) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (panel == null) Flexible(child: top) else ConstrainedBox(constraints: BoxConstraints(maxHeight: c.maxHeight / 2), child: top),
                    if (!previewing && !guiding && nav.fromPlace != null) Padding(padding: const EdgeInsets.only(top: 8), child: _fromChip(context)),
                    if (panel != null) ...[
                      const SizedBox(height: 8),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, room) => Align(
                            alignment: guiding ? Alignment.bottomCenter : Alignment.topCenter,
                            child: SingleChildScrollView(child: SizedBox(width: double.infinity, child: _panel(searching, maxHeight: room.maxHeight))),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!searching)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (fix != null && !guiding) Flexible(child: _coordsChip(context, fix)),
                        const Spacer(),
                        _controls(context, fix, follow),
                      ],
                    ),
                  const Spacer(),
                  if (maps.notice != null && panel == null) ...[
                    Center(child: NoticePill(text: maps.notice!)),
                    const SizedBox(height: 8),
                  ],
                  if (!searching)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ScaleBarWidget(lat: _scaleView.$1, zoom: _scaleView.$2),
                              const SizedBox(height: 6),
                              AttributionChip(lines: maps.attributions, onTap: _showCredits),
                            ],
                          ),
                        ),
                        if (_insetOn && !_insetHidden) ...[const SizedBox(width: 8), _inset(context)],
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "From (a place): choose where to go", with the way back to starting from where you are.
  Widget _fromChip(BuildContext context) => Container(
      key: const ValueKey('from-chip'),
      padding: const EdgeInsets.only(left: 14),
      decoration: mapPanel(context, radius: 16),
      child: Row(
        children: [
          Icon(Icons.trip_origin, size: 18, color: context.t.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text('From ${nav.fromPlace!.name}: choose where to go',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: context.t.text)),
          ),
          IconButton(
            tooltip: 'Start from your location',
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            icon: const Icon(Icons.close, size: 18),
            onPressed: nav.clearFrom,
          ),
        ],
      ),
    );

  /// The bottom: the scale and credits, and above them the place card, the way to go, or the guidance bar.
  Widget _bottomLayer(BuildContext context) {
    final searching = nav.searchOpen && nav.phase == NavPhase.browsing && nav.query.trim().isNotEmpty;
    final panel = _panel(searching);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, panel == null ? 8 : 0),
        child: SafeArea(
          top: false,
          // The guidance card sits above the home indicator (the card itself has no empty strip at its foot).
          bottom: panel == null || nav.guiding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (maps.notice != null && panel == null) ...[
                Center(child: NoticePill(text: maps.notice!)),
                const SizedBox(height: 8),
              ],
              if (!searching) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ScaleBarWidget(lat: _scaleView.$1, zoom: _scaleView.$2),
                          const SizedBox(height: 6),
                          AttributionChip(lines: maps.attributions, onTap: _showCredits),
                        ],
                      ),
                    ),
                    if (_insetOn && !_insetHidden) ...[const SizedBox(width: 8), _inset(context)],
                  ],
                ),
                const SizedBox(height: 8),
              ],
              // (From kSideCardWidth wide the panels sit in a column on the left: see _sideLayers.)
              if (panel != null && !searching)
                SizedBox(
                  width: double.infinity,
                  child: Padding(padding: const EdgeInsets.only(bottom: 8), child: panel),
                ),
            ],
          ),
        ),
      ),
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

/// A press and hold on the map: where (on screen and on the map), the spot's name once known, and which ring shows.
class _Ring {
  _Ring({required this.at, required this.lat, required this.lon});

  final Offset at;
  final double lat;
  final double lon;
  String? name;

  /// The notebook ring (after Save), and its page.
  bool notebooks = false;
  int page = 0;
}

/// The measuring bar: the running total in the person's units, how many points, Undo for the last point, and Done.
class MeasurePanel extends StatelessWidget {
  const MeasurePanel({super.key, required this.total, required this.points, required this.canUndo, required this.onUndo, required this.onDone});

  final String total;
  final int points;
  final bool canUndo;
  final VoidCallback onUndo;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      key: const ValueKey('measure-panel'),
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: mapPanel(context, radius: 20, alpha: 0.98),
      child: Row(
        children: [
          Icon(Icons.straighten, color: k.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(total, key: const ValueKey('measure-total'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: k.text)),
                Text(points < 2 ? 'Tap the map to add points' : '$points points · tap the map to add more',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.secondary)),
              ],
            ),
          ),
          TextButton(key: const ValueKey('measure-undo'), onPressed: canUndo ? onUndo : null, child: const Text('Undo')),
          FilledButton(key: const ValueKey('measure-done'), onPressed: onDone, child: const Text('Done')),
        ],
      ),
    );
  }
}
