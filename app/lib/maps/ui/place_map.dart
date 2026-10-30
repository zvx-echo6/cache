import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../notebook/notebook_model.dart';
import '../../theme.dart';
import '../maps_state.dart';
import '../palette/map_palette.dart';
import '../style/style_generator.dart';
import 'map_assets.dart';

/// A small map with one pin, the place screen's: the same style as Maps (its layers, its theme), centred on [pin]. With
/// [onPick], a tap moves the pin there.
class PlaceMap extends StatefulWidget {
  const PlaceMap({super.key, required this.maps, required this.themeId, required this.pin, this.onPick});

  final MapsState maps;
  final CacheThemeId themeId;
  final NbPlace? pin;
  final ValueChanged<NbPlace>? onPick;

  @override
  State<PlaceMap> createState() => _PlaceMapState();
}

class _PlaceMapState extends State<PlaceMap> {
  String? _style;
  MapLibreMapController? _c;
  bool _ready = false;

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
    if (old.pin != widget.pin) _showPin(move: true);
  }

  Future<void> _showPin({bool move = false}) async {
    final c = _c, p = widget.pin;
    if (c == null || !_ready) return;
    try {
      await c.setGeoJsonSource(kPinSource, {
        'type': 'FeatureCollection',
        'features': [
          if (p != null)
            {
              'type': 'Feature',
              'geometry': {'type': 'Point', 'coordinates': [p.lon, p.lat]},
              'properties': {'role': 'selected', 'id': 'place'},
            },
        ],
      });
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
        _showPin();
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
