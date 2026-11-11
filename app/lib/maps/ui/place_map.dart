import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show Factory;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../notebook/notebook_map.dart' show PinLook;
import '../../notebook/notebook_model.dart';
import '../../notebook/pin_image.dart';
import '../../theme.dart';
import '../maps_state.dart';
import '../palette/map_palette.dart';
import '../style/style_generator.dart';
import 'map_assets.dart';

/// A small map with one pin, the place screen's: the same style as Maps (its layers, its theme), centred on [pin]. With
/// [onPick], a tap moves the pin there, and the map takes drag and pinch itself (inside the place form's scrolling list too).
/// Without [onPick] it is a view: the page's scroll keeps the gestures. [onCentre] is told where the middle of the map is when the
/// camera comes to rest (the full-screen picker's crosshair); [showPin] false leaves the pin out (the picker draws its own).
class PlaceMap extends StatefulWidget {
  const PlaceMap({super.key, required this.maps, required this.themeId, required this.pin, this.onPick, this.onCentre, this.onMoving, this.showPin = true, this.look});

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

  @override
  State<PlaceMap> createState() => _PlaceMapState();
}

class _PlaceMapState extends State<PlaceMap> {
  String? _style;
  MapLibreMapController? _c;
  bool _ready = false;
  PinImages? _images;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final glyphs = await MapAssets.glyphsUrl();
      final s = await widget.maps.styleJson(mapPaletteFor(widget.themeId), glyphs);
      if (mounted) setState(() => _style = s);
    } catch (_) {}
  }

  @override
  void didUpdateWidget(PlaceMap old) {
    super.didUpdateWidget(old);
    if (old.pin != widget.pin) {
      _showPin(move: true);
    } else if (old.look?.icon.id != widget.look?.icon.id || old.look?.tint != widget.look?.tint) {
      _showPin();
    }
  }

  Future<void> _showPin({bool move = false}) async {
    final c = _c, p = widget.pin;
    if (c == null || !_ready) return;
    try {
      final look = widget.look;
      String? image;
      if (look != null && widget.showPin) {
        final images = _images ??= PinImages((name, png) => c.addImage(name, png), widget.maps.pinStyle, tactical: widget.themeId == CacheThemeId.tactical);
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
      if (move && p != null) await c.animateCamera(CameraUpdate.newLatLng(LatLng(p.lat, p.lon)));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = _style;
    final p = widget.pin;
    if (s == null) return ColoredBox(color: context.t.surface, child: const Center(child: CircularProgressIndicator()));
    return MapLibreMap(
      styleString: s,
      initialCameraPosition: CameraPosition(target: LatLng(p?.lat ?? 39.8, p?.lon ?? -98.6), zoom: p == null ? 3 : 14),
      onMapCreated: (c) {
        _c = c;
        c.forceOnlineMode().catchError((_) {});
      },
      onStyleLoadedCallback: () {
        _ready = true;
        _images = null;
        _showPin();
      },
      gestureRecognizers: widget.onPick == null ? null : {Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new)},
      onCameraMove: widget.onMoving == null ? null : (c) => widget.onMoving!(NbPlace(lat: c.target.latitude, lon: c.target.longitude)),
      onCameraIdle: widget.onCentre == null
          ? null
          : () {
              final t = _c?.cameraPosition?.target;
              if (t != null) widget.onCentre!(NbPlace(lat: t.latitude, lon: t.longitude));
            },
      onMapClick: widget.onPick == null ? null : (math.Point<double> _, LatLng at) => widget.onPick!(NbPlace(lat: at.latitude, lon: at.longitude)),
      compassEnabled: false,
      tiltGesturesEnabled: false,
      rotateGesturesEnabled: false,
      logoEnabled: false,
      attributionButtonMargins: const math.Point(-200, -200),
      myLocationEnabled: false,
    );
  }
}
