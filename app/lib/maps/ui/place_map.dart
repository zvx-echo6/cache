import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show Factory, visibleForTesting;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../notebook/notebook_map.dart' show PinLook;
import '../../notebook/notebook_model.dart';
import '../../notebook/pin_image.dart';
import '../../theme.dart';
import '../geo.dart';
import '../maps_state.dart';
import '../palette/map_palette.dart';
import '../style/style_generator.dart';
import 'map_assets.dart';

/// The zoom the place map shows a place at: street level. Used when it opens on a pin and when a position (the phone's fix, a
/// search result, "Where I am") sets the pin. The person's own taps and drags do not change the zoom.
const double kPlaceZoom = 16;

/// How long the map waits for the phone's position before it opens without one.
const Duration kPlaceFixWait = Duration(seconds: 3);

/// Below this zoom a tap on the place map zooms in on the tapped spot instead of moving the pin, so a place can never be saved
/// from a wide view by one tap.
const double kPrecisePlaceZoom = 10;

/// The last resort when there is no pin, no fix, no remembered camera, no places and no downloaded region: the wide view. Taps
/// zoom in on it ([kPrecisePlaceZoom]) before they place anything.
const ({double lat, double lon, double zoom}) kPlaceWideView = (lat: 39.8, lon: -98.6, zoom: 3);

/// A camera to open on when there is no position: the Maps tab's last camera (when it was zoomed in to somewhere), else the
/// centre of [places] fitted to them, else the centre of a downloaded map region ([regions], the largest one) fitted to it (never
/// closer than [kPlaceZoom]), else null (the caller falls back to [kPlaceWideView]).
({double lat, double lon, double zoom})? placeFallbackCamera({SavedCamera? last, List<NbPlace> places = const [], List<GeoBounds> regions = const []}) {
  if (last != null && last.zoom >= 6) return (lat: last.lat, lon: last.lon, zoom: last.zoom);
  // The places, or else the largest downloaded region: the centre of their bounds at the zoom that fits them.
  final boxes = places.isNotEmpty
      ? [GeoBounds(south: places.map((p) => p.lat).reduce(math.min), west: places.map((p) => p.lon).reduce(math.min), north: places.map((p) => p.lat).reduce(math.max), east: places.map((p) => p.lon).reduce(math.max))]
      : regions;
  if (boxes.isEmpty) return null;
  GeoBounds big = boxes.first;
  for (final r in boxes) {
    if (_span(r) > _span(big)) big = r;
  }
  return (lat: big.centerLat, lon: big.centerLon, zoom: _fitZoom(_span(big)));
}

double _span(GeoBounds b) => math.max(b.north - b.south, b.east - b.west);

/// The zoom at which an area [span] degrees across fits the map (a 360-degree world is 256 px wide at zoom 0 and doubles per zoom,
/// so about 300 px of map shows it), clamped to 3..[kPlaceZoom]; a single point, or a tiny area, is [kPlaceZoom].
double _fitZoom(double span) => span <= 0 ? kPlaceZoom : (math.log(360 / span) / math.ln2).clamp(3.0, kPlaceZoom).toDouble();

/// Tells a [PlaceMap] under it whether a position fix is still being read. With none coming (the phone answered "no position", or
/// location is off) the map opens on its fallback at once instead of waiting [kPlaceFixWait].
class PlaceFixScope extends InheritedWidget {
  const PlaceFixScope({super.key, required this.coming, required super.child});

  final bool coming;

  static bool comingOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PlaceFixScope>()?.coming ?? true;

  @override
  bool updateShouldNotify(PlaceFixScope old) => old.coming != coming;
}

/// What tests put in place of the platform map: the surface drawn, the style, and where the camera is told to go.
@visibleForTesting
class PlaceMapHooks {
  const PlaceMapHooks({required this.surface, required this.camera, this.loadStyle});

  /// Draws the map at [initial]; calls [styleLoaded] when its style is ready and [tapped] for a tap on it.
  final Widget Function(BuildContext context, CameraPosition initial, VoidCallback styleLoaded, ValueChanged<LatLng> tapped) surface;

  /// A camera move after the map opened: [zoom] null keeps the zoom.
  final void Function(LatLng target, double? zoom) camera;
  final Future<String> Function()? loadStyle;
}

/// A small map with one pin, the place screen's: the same style as Maps (its layers, its theme), centred on [pin]. With
/// [onPick], a tap moves the pin there, and the map takes drag and pinch itself (inside the place form's scrolling list too).
/// Without [onPick] it is a view: the page's scroll keeps the gestures. [onCentre] is told where the middle of the map is when the
/// camera comes to rest (the full-screen picker's crosshair); [showPin] false leaves the pin out (the picker draws its own).
class PlaceMap extends StatefulWidget {
  const PlaceMap({super.key, required this.maps, required this.themeId, required this.pin, this.onPick, this.onCentre, this.onMoving, this.showPin = true, this.look, this.fallback, this.hooks});

  final MapsState maps;
  final CacheThemeId themeId;
  final NbPlace? pin;
  final ValueChanged<NbPlace>? onPick;
  final ValueChanged<NbPlace>? onCentre;

  /// The middle of the map while the camera moves (live coordinates).
  final ValueChanged<NbPlace>? onMoving;
  final bool showPin;

  /// The pin's icon and colour (the place's current ones); drawn in the person's Pin style with the same images as the Maps screen.
  /// Null draws the plain dot.
  final PinLook? look;

  /// Where to open when there is no pin after [kPlaceFixWait] (the Maps tab's last camera, the notebook's places), or null.
  final Future<({double lat, double lon, double zoom})?> Function()? fallback;

  @visibleForTesting
  final PlaceMapHooks? hooks;

  @override
  State<PlaceMap> createState() => _PlaceMapState();
}

class _PlaceMapState extends State<PlaceMap> {
  String? _style;
  MapLibreMapController? _c;
  bool _ready = false;
  PinImages? _images;

  /// The camera the map was opened on; null until the map is built (the spinner shows until then, at most the style's load and
  /// [kPlaceFixWait] with no pin).
  CameraPosition? _initial;
  Timer? _wait;
  bool _waited = false;
  bool _opening = false;

  /// The pin the camera was last aimed at, and the last tap on the map (a pin that came from a tap keeps the zoom).
  NbPlace? _aimed;
  LatLng? _tapAt;

  /// The zoom the camera is at (read from the map when it reports one).
  double _zoom = kPlaceZoom;

  @override
  void initState() {
    super.initState();
    _wait = Timer(kPlaceFixWait, () {
      _waited = true;
      _tryOpen();
    });
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initial == null && _style != null) unawaited(_tryOpen());
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final h = widget.hooks?.loadStyle;
      final String s;
      if (h != null) {
        s = await h();
      } else {
        final glyphs = await MapAssets.glyphsUrl();
        s = await widget.maps.styleJson(mapPaletteFor(widget.themeId), glyphs);
      }
      if (!mounted) return;
      setState(() => _style = s);
      unawaited(_tryOpen());
    } catch (_) {}
  }

  /// Opens the map once the style is loaded and either the pin is known or [kPlaceFixWait] has passed: on the pin at
  /// [kPlaceZoom], else on the fallback camera. Never on the whole continent, never waiting for ever.
  Future<void> _tryOpen() async {
    if (!mounted || _initial != null || _opening || _style == null) return;
    final p = widget.pin;
    if (p == null && !_waited && PlaceFixScope.comingOf(context)) return;
    _opening = true;
    CameraPosition? cam;
    if (p == null) {
      var f = kPlaceWideView;
      try {
        f = await widget.fallback?.call() ?? kPlaceWideView;
      } catch (_) {}
      cam = CameraPosition(target: LatLng(f.lat, f.lon), zoom: f.zoom);
    }
    if (!mounted) return;
    // A pin that arrived while the fallback was being read wins.
    final q = widget.pin;
    if (q != null) {
      _aimed = q;
      cam = CameraPosition(target: LatLng(q.lat, q.lon), zoom: kPlaceZoom);
    }
    _zoom = cam!.zoom;
    setState(() => _initial = cam);
  }

  @override
  void didUpdateWidget(PlaceMap old) {
    super.didUpdateWidget(old);
    if (old.pin != widget.pin) {
      _tryOpen();
      _showPin();
      _aim(force: true);
    } else if (old.look?.icon.id != widget.look?.icon.id || old.look?.tint != widget.look?.tint) {
      _showPin();
    }
  }

  /// Aims the camera at the pin when it changed. A pin from the person's tap recentres and keeps the zoom; any other (the
  /// phone's position, a search result, "Where I am") goes to [kPlaceZoom].
  void _aim({bool force = false}) {
    final p = widget.pin;
    if (p == null || !_ready || _initial == null) return;
    final a = _aimed;
    if (!force && a != null && a.lat == p.lat && a.lon == p.lon) return;
    _aimed = p;
    final t = _tapAt;
    final fromTap = t != null && (t.latitude - p.lat).abs() < 1e-9 && (t.longitude - p.lon).abs() < 1e-9;
    _tapAt = null;
    _move(LatLng(p.lat, p.lon), fromTap ? null : kPlaceZoom);
  }

  Future<void> _move(LatLng target, double? zoom) async {
    if (zoom != null) _zoom = zoom;
    final h = widget.hooks;
    if (h != null) return h.camera(target, zoom);
    final c = _c;
    if (c == null) return;
    try {
      await c.animateCamera(zoom == null ? CameraUpdate.newLatLng(target) : CameraUpdate.newLatLngZoom(target, zoom));
    } catch (_) {}
  }

  void _tap(LatLng at) {
    final z = widget.hooks == null ? (_c?.cameraPosition?.zoom ?? _zoom) : _zoom;
    _zoom = z;
    // From a wide view a tap only zooms in on the spot; the pin is placed by a tap once the map is close.
    if (z < kPrecisePlaceZoom) {
      _tapAt = null;
      _move(at, kPrecisePlaceZoom);
      return;
    }
    _tapAt = at;
    widget.onPick?.call(NbPlace(lat: at.latitude, lon: at.longitude));
  }

  void _styleLoaded() {
    _ready = true;
    _images = null;
    _showPin();
    _aim();
  }

  Future<void> _showPin() async {
    final c = _c, p = widget.pin;
    if (c == null || !_ready) return;
    try {
      final look = widget.look;
      String? image;
      if (look != null && widget.showPin) {
        final images = _images ??= PinImages((name, png) => c.addImage(name, png), widget.maps.pinStyle,
            tactical: widget.themeId == CacheThemeId.tactical, ratio: pinImageRatio(mounted ? MediaQuery.devicePixelRatioOf(context) : 1.0));
        image = await images.ensure(look.icon.id, look.glyph, look.tint);
      }
      Map<String, dynamic> one(bool on, Map<String, dynamic> props) => {
            'type': 'FeatureCollection',
            'features': [
              if (on && p != null && widget.showPin)
                {
                  'type': 'Feature',
                  'geometry': {'type': 'Point', 'coordinates': [p.lon, p.lat]},
                  'properties': props,
                },
            ],
          };
      // With a look the pin is the notebook pins' symbol layer drawing the image; without one, the plain dot.
      await c.setGeoJsonSource(kPinSource, one(image == null, {'role': 'selected', 'id': 'place'}));
      await c.setGeoJsonSource(kNotebookSource, one(image != null, {'pin': image, 'title': 'place'}));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = _style, init = _initial;
    if (s == null || init == null) return ColoredBox(color: context.t.surface, child: const Center(child: CircularProgressIndicator()));
    final h = widget.hooks;
    if (h != null) return h.surface(context, init, _styleLoaded, _tap);
    return MapLibreMap(
      styleString: s,
      initialCameraPosition: init,
      onMapCreated: (c) {
        _c = c;
        c.forceOnlineMode().catchError((_) {});
      },
      onStyleLoadedCallback: _styleLoaded,
      gestureRecognizers: widget.onPick == null ? null : {Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new)},
      onCameraMove: widget.onMoving == null ? null : (c) => widget.onMoving!(NbPlace(lat: c.target.latitude, lon: c.target.longitude)),
      onCameraIdle: widget.onCentre == null
          ? null
          : () {
              final t = _c?.cameraPosition?.target;
              if (t != null) widget.onCentre!(NbPlace(lat: t.latitude, lon: t.longitude));
            },
      onMapClick: widget.onPick == null ? null : (math.Point<double> _, LatLng at) => _tap(at),
      compassEnabled: false,
      tiltGesturesEnabled: false,
      rotateGesturesEnabled: false,
      logoEnabled: false,
      attributionButtonMargins: const math.Point(-200, -200),
      myLocationEnabled: false,
      trackCameraPosition: true,
    );
  }
}
